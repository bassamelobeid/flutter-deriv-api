package Binary::WebSocketAPI;

use strict;
use warnings;

no indirect;

use Binary::WebSocketAPI::BalanceConnections ();
use Mojo::Base 'Mojolicious';
use Mojo::Redis2;
use Mojo::IOLoop;
use Mojo::WebSocketProxy::Backend::JobAsync;
use IO::Async::Loop::Mojo;

use Binary::WebSocketAPI::Actions;
use Binary::WebSocketAPI::Hooks;

use Binary::WebSocketAPI::v3::Wrapper::DocumentUpload;
use Binary::WebSocketAPI::v3::Instance::Redis qw| check_connections ws_redis_master redis_queue |;

use Brands;
use Encode;
use DataDog::DogStatsd::Helper;
use Digest::MD5 qw(md5_hex);
use Format::Util::Strings qw( defang );
use JSON::MaybeXS;
use JSON::MaybeUTF8 qw(decode_json_utf8);
use Mojolicious::Plugin::ClientIP::Pluggable;
use Path::Tiny;
use RateLimitations::Pluggable;
use Scalar::Util qw(weaken);
use Time::Duration::Concise;
use YAML::XS qw(LoadFile);
use URI;
use List::Util qw( first );
use Try::Tiny;

# to block apps from certain operations_domains (red, green etc ) enter the color/name of the domain to the list
# with the associated list of app_id's
# Currently 3rd Party Uses red only.
use constant APPS_BLOCKED_FROM_OPERATION_DOMAINS => {red => [1]};

# Set up the event loop singleton so that any code we pull in uses the Mojo
# version, rather than trying to set its own.
local $ENV{IO_ASYNC_LOOP} = 'IO::Async::Loop::Mojo';
my $loop = IO::Async::Loop->new;
die 'Unexpected event loop class: had ' . ref($loop) . ', expected a subclass of IO::Async::Loop::Mojo'
    unless $loop->isa('IO::Async::Loop::Mojo')
    and IO::Async::Loop->new->isa('IO::Async::Loop::Mojo');

# These are the apps that are hardcoded to point to a different server pool.
# This list is overwritten by Redis.
our %DIVERT_APP_IDS;

# These apps are blocked entirely.
# This list is also overwritten by Redis.
our %BLOCK_APP_IDS;
our %BLOCK_ORIGINS;

# Keys are RPC calls that we want RPC to log, controlled by redis too.
our %RPC_LOGGING;

# API method (action) settings stored in a hash
our $WS_ACTIONS;

# websocket RPC backends
our $WS_BACKENDS;

my $node_config;

sub apply_usergroup {
    my ($cf, $log) = @_;

    if ($> == 0) {    # we are root
        my $group = $cf->{group};
        if ($group) {
            $group = (getgrnam $group)[2] unless $group =~ /^\d+$/;
            $(     = $group;                                          ## no critic (RequireLocalizedPunctuationVars)
            $)     = "$group $group";                                 ## no critic (RequireLocalizedPunctuationVars)
            $log->("Switched group: RGID=$( EGID=$)");
        }

        my $user = $cf->{user} // 'nobody';
        if ($user) {
            $user = (getpwnam $user)[2] unless $user =~ /^\d+$/;
            $<    = $user;                                            ## no critic (RequireLocalizedPunctuationVars)
            $>    = $user;                                            ## no critic (RequireLocalizedPunctuationVars)
            $log->("Switched user: RUID=$< EUID=$>");
        }
    }
    return;
}

sub startup {
    my $app = shift;
    my $log = $app->log;

    check_connections();                                              ### Raise and check redis connections

    Mojo::IOLoop->singleton->reactor->on(
        error => sub {
            my (undef, $err) = @_;
            $app->log->error("EventLoop error: $err");
        });

    $app->moniker('websocket');
    $app->plugin('Config' => {file => $ENV{WEBSOCKET_CONFIG} || '/etc/rmg/websocket.conf'});

    $log->info("Binary.com Websockets API: Starting.");
    $log->info("Mojolicious Mode is " . $app->mode);
    $log->info("Log Level        is " . $log->level);

    apply_usergroup $app->config->{hypnotoad}, sub {
        $log->info(@_);
    };
    $node_config = YAML::XS::LoadFile('/etc/rmg/node.yml');
    # binary.com plugins
    push @{$app->plugins->namespaces}, 'Binary::WebSocketAPI::Plugins';
    $app->plugin('Introspection' => {port => 0});
    $app->plugin('RateLimits');
    $app->plugin('Longcode');
    $app->plugin('EVMonitor' => {interval => 1});

    $app->hook(
        before_dispatch => sub {
            my $c = shift;

            return unless $c->tx;

            my $lang = defang($c->param('l'));
            if ($lang =~ /^\D{2}(_\D{2})?$/) {
                $c->stash(language => uc $lang);
                $c->res->headers->header('Content-Language' => lc $lang);
            } else {
                # default to English if not valid language
                $c->stash(language => 'EN');
                $c->res->headers->header('Content-Language' => 'en');
            }

            if ($c->req->param('debug')) {
                $c->stash(debug => 1);
            }

            my $app_id = $c->app_id;
            return $c->render(
                json   => {error => 'InvalidAppID'},
                status => 401
            ) unless $app_id;

            return $c->render(
                json   => {error => 'AccessRestricted'},
                status => 403
            ) if exists $BLOCK_APP_IDS{$app_id};

            # app_id 1 which is our static site should not be used on Red environment which is for 3rd party developers.
            return $c->render(
                json   => {error => 'AccessRestricted'},
                status => 403
            ) if first { $app_id == $_ } APPS_BLOCKED_FROM_OPERATION_DOMAINS->{$node_config->{node}->{operation_domain} // ''}->@*;

            my $request_origin = $c->tx->req->headers->origin // '';
            $request_origin = 'https://' . $request_origin unless $request_origin =~ /^https?:/;
            my $uri = URI->new($request_origin);
            return $c->render(
                json   => {error => 'AccessRestricted'},
                status => 403
            ) if exists $BLOCK_ORIGINS{$uri->host};

            my $client_ip = $c->client_ip;
            #TODO is this brand that brand ? can be used to create a Brands object ?
            my $brand_name = defang($c->req->param('brand')) // 'binary';
            my $binary_brand = Brands->new(name => $brand_name);

            if ($c->tx and $c->tx->req and $c->tx->req->headers->header('REMOTE_ADDR')) {
                $client_ip = $c->tx->req->headers->header('REMOTE_ADDR');
            }

            my $user_agent = $c->req->headers->header('User-Agent');

            # We'll forward the domain for constructing URLs such as cashier. Note that we are
            # not guaranteed to have referrer information so the stash value may not always
            # be set.
            if (my $domain = $c->req->headers->header('Origin')) {
                my $name = $binary_brand->name;
                if (my ($domain_without_prefix) = $domain =~ m{^(?:https://)?\S+($name\.\S+)$}) {
                    $c->stash(domain => $domain_without_prefix);
                }
            }

            $c->stash(
                server_name          => $c->server_name,
                client_ip            => $client_ip,
                referrer             => $c->req->headers->header('Origin'),
                country_code         => $c->country_code,
                landing_company_name => $c->landing_company_name,
                user_agent           => $user_agent,
                ua_fingerprint       => md5_hex(($app_id // 0) . ($client_ip // '') . ($user_agent // '')),
                ($app_id) ? (source => $app_id) : (),
                brand => (($brand_name =~ /^\w{1,10}$/) ? $brand_name : $binary_brand->name),
            );
        });

    $app->plugin(
        'Mojolicious::Plugin::ClientIP::Pluggable',
        analyze_headers => [qw/cf-pseudo-ipv4 cf-connecting-ip true-client-ip/],
        restrict_family => 'ipv4',
        fallbacks       => [qw/rfc-7239 x-forwarded-for remote_address/]);
    $app->plugin('Binary::WebSocketAPI::Plugins::Helpers');

    my $actions = Binary::WebSocketAPI::Actions::actions_config();

    my $backend_redis = redis_queue();
    my $queue_prefix = $ENV{JOB_QUEUE_PREFIX} // $app->config->{queue_prefix};
    $WS_BACKENDS = {
        queue_backend => {
            type  => "job_async",
            redis => {
                uri     => 'redis://' . $backend_redis->url->host . ':' . $backend_redis->url->port,
                timeout => 5,
                $queue_prefix ? (prefix => $queue_prefix) : (),
            }
        },
    };

    my $json = JSON::MaybeXS->new;

    for my $action (@$actions) {
        my $action_name = $action->[0];
        my $f           = '/home/git/regentmarkets/binary-websocket-api/config/v3';
        my $schema_send = $json->decode(path("$f/$action_name/send.json")->slurp_utf8);

        my $action_options = $action->[1] ||= {};
        $action_options->{schema_send} = $schema_send;
        $action_options->{stash_params} ||= [];
        push @{$action_options->{stash_params}}, qw( language country_code );
        push @{$action_options->{stash_params}}, 'token' if $schema_send->{auth_required};

        $WS_ACTIONS->{$action_name} = $action_options;
    }

    $app->helper(
        'app_id' => sub {
            my $c = shift;
            return undef unless $c->tx;
            my $possible_app_id = $c->req->param('app_id');
            if (defined($possible_app_id) && $possible_app_id =~ /^(?!0)[0-9]{1,19}$/) {
                return $possible_app_id;
            }
            return undef;
        });

    $app->helper(
        'rate_limitations_key' => sub {
            my $c = shift;
            return "rate_limits::closed" unless $c && $c->tx;

            my $app_id   = $c->app_id;
            my $login_id = $c->stash('loginid');
            return "rate_limits::authorised::$app_id/$login_id" if $login_id;

            my $ip = $c->client_ip;
            if ($ip) {
                # Basic sanitisation: we expect IPv4/IPv6 addresses only, reject anything else
                $ip =~ s{[^[:xdigit:]:.]+}{_}g;
            } else {
                DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.unknown_ip.count');
                $ip = 'UNKNOWN';
            }

            # We use empty string for the default UA since we'll be hashing anyway
            # and our highly-trained devops team can spot an md5('') from orbit
            my $user_agent = $c->req->headers->header('User-Agent') // '';
            my $client_id = $ip . ':' . md5_hex($user_agent);
            return "rate_limits::unauthorised::$app_id/$client_id";
        });

    $app->plugin(
        'web_socket_proxy' => {
            binary_frame => \&Binary::WebSocketAPI::v3::Wrapper::DocumentUpload::document_upload,
            # action hooks
            before_forward => [
                \&Binary::WebSocketAPI::Hooks::start_timing,      \&Binary::WebSocketAPI::Hooks::before_forward,
                \&Binary::WebSocketAPI::Hooks::assign_rpc_url,    \&Binary::WebSocketAPI::Hooks::introspection_before_forward,
                \&Binary::WebSocketAPI::Hooks::assign_ws_backend, \&Binary::WebSocketAPI::Hooks::check_app_id
            ],
            before_call => [
                \&Binary::WebSocketAPI::Hooks::log_call_timing_before_forward, \&Binary::WebSocketAPI::Hooks::add_app_id,
                \&Binary::WebSocketAPI::Hooks::add_log_config,                 \&Binary::WebSocketAPI::Hooks::add_brand,
                \&Binary::WebSocketAPI::Hooks::start_timing,                   \&Binary::WebSocketAPI::Hooks::cleanup_stored_contract_ids
            ],
            before_get_rpc_response  => [\&Binary::WebSocketAPI::Hooks::log_call_timing],
            after_got_rpc_response   => [\&Binary::WebSocketAPI::Hooks::log_call_timing_connection, \&Binary::WebSocketAPI::Hooks::error_check],
            before_send_api_response => [
                \&Binary::WebSocketAPI::Hooks::add_req_data,      \&Binary::WebSocketAPI::Hooks::start_timing,
                \&Binary::WebSocketAPI::Hooks::output_validation, \&Binary::WebSocketAPI::Hooks::add_call_debug,
                \&Binary::WebSocketAPI::Hooks::introspection_before_send_response
            ],
            after_sent_api_response => [\&Binary::WebSocketAPI::Hooks::log_call_timing_sent, \&Binary::WebSocketAPI::Hooks::close_bad_connection],

            # main config
            base_path         => '/websockets/v3',
            stream_timeout    => 120,
            max_connections   => 100000,
            max_response_size => 600000,                                                # change and test this if we ever increase ticks history count
            opened_connection => \&Binary::WebSocketAPI::Hooks::on_client_connect,
            finish_connection => \&Binary::WebSocketAPI::Hooks::on_client_disconnect,

            # helper config
            url     => \&Binary::WebSocketAPI::Hooks::assign_rpc_url,                   # make url for manually called actions
            actions => $actions,
            # Skip check sanity to password fields
            skip_check_sanity => qr/password/,
            backends          => $WS_BACKENDS,
        });

    my $redis = ws_redis_master();
    $redis->get(
        'app_id::diverted',
        sub {
            my ($redis, $err, $ids) = @_;
            if ($err) {
                $log->error("Error reading diverted app IDs from Redis: $err");
                return;
            }
            return unless $ids;
            $log->info("Have diverted app_ids, applying: $ids");
            # We'd expect this to be an empty hashref - i.e. true - if there's a value back from Redis.
            # No value => no update.
            %Binary::WebSocketAPI::DIVERT_APP_IDS = %{$json->decode(Encode::decode_utf8($ids))};
        });
    $redis->get(
        'app_id::blocked',
        sub {
            my ($redis, $err, $ids) = @_;
            if ($err) {
                $log->error("Error reading blocked app IDs from Redis: $err");
                return;
            }
            return unless $ids;
            $log->info("Have blocked app_ids, applying: $ids");
            %BLOCK_APP_IDS = %{$json->decode(Encode::decode_utf8($ids))};
        });
    $redis->get(
        'origins::blocked',
        sub {
            my ($redis, $err, $origins) = @_;
            if ($err) {
                $log->error("Error reading blocked origins from Redis: $err");
                return;
            }
            return unless $origins;
            $log->info("Have blocked origins, applying: $origins");
            %BLOCK_ORIGINS = %{$json->decode(Encode::decode_utf8($origins))};
        });
    $redis->get(
        'rpc::logging',
        sub {
            my ($redis, $err, $logging) = @_;
            if ($err) {
                $log->error("Error reading RPC logging config from Redis: $err");
                return;
            }
            %RPC_LOGGING = $logging ? $json->decode(Encode::decode_utf8($logging))->%* : ();
            $log->info("Enabled logging for RPC: " . join(', ', keys %RPC_LOGGING)) if %RPC_LOGGING;
        });

    my $backend_setup_finished = 0;
    $redis->get(
        'web_socket_proxy::backends',
        sub {
            my ($redis, $err, $backends_str) = @_;
            if ($err) {
                $log->error("Error reading backends from master redis: $err");
            }

            if ($backends_str) {
                $log->info("Found rpc backends in redis, applying.");
                try {
                    my $backends = decode_json_utf8($backends_str);
                    for my $method (keys %$backends) {
                        my $backend = $backends->{$method} // 'default';
                        $backend = 'default' if $backend eq 'http';
                        if (exists $WS_ACTIONS->{$method} and ($backend eq 'default' or exists $WS_BACKENDS->{$backend})) {
                            $WS_ACTIONS->{$method}->{backend} = $backend;
                        } else {
                            $log->warn("Invalid  backend setting ignored: <$method $backend>");
                        }
                    }
                    $backend_setup_finished = 1;
                }
                catch {
                    $log->error("Error applying backends from master: $@");
                };
            } else {    # there is nothing saved in redis yet.
                $backend_setup_finished = 1;
            }
        });

    for (my $seconds = 0.5; $seconds <= 4; $seconds *= 2) {
        my $timeout = 0;
        Mojo::IOLoop->timer($seconds => sub { ++$timeout });
        Mojo::IOLoop->one_tick while !($timeout or $backend_setup_finished);
        last if $backend_setup_finished;
        $log->error("Timeout $seconds sec. reached when trying to load backends from master redis.");
    }

    unless ($backend_setup_finished) {
        die 'Failed to read rpc backends from master redis. Please retry after ensuring that master redis is started.';
    }

    return;
}

1;
