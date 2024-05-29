package Binary::WebSocketAPI;

use strict;
use warnings;

no indirect;

use Binary::WebSocketAPI::BalanceConnections ();
use Mojo::Base 'Mojolicious';
use Mojo::Redis2;
use Mojo::IOLoop;
use Mojo::WebSocketProxy::Backend::ConsumerGroups;
use IO::Async::Loop::Mojo;

use Binary::WebSocketAPI::Actions;
use Binary::WebSocketAPI::Hooks;

use Binary::WebSocketAPI::v3::Wrapper::DocumentUpload;
use Binary::WebSocketAPI::v3::Instance::Redis qw( check_connections ws_redis_master redis_rpc );
use Binary::WebSocketAPI::v3::Wrapper::Streamer;

use Encode;
use DataDog::DogStatsd::Helper;
use Digest::MD5           qw(md5_hex);
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
use List::Util qw( first any );
use Syntax::Keyword::Try;
use Log::Any      qw($log);
use Future::Utils qw(fmap);
use Scalar::Util  qw(blessed);

# Set up the event loop singleton so that any code we pull in uses the Mojo
# version, rather than trying to set its own.
local $ENV{IO_ASYNC_LOOP} = 'IO::Async::Loop::Mojo';
my $loop = IO::Async::Loop->new;
die 'Unexpected event loop class: had ' . ref($loop) . ', expected a subclass of IO::Async::Loop::Mojo'
    unless $loop->isa('IO::Async::Loop::Mojo')
    and IO::Async::Loop->new->isa('IO::Async::Loop::Mojo');

use constant VALID_BRANDS  => qw(binary deriv);
use constant DEFAULT_BRAND => 'deriv';
use constant RPC_TIMEOUT_DEFAULT => {
    rpc        => '',
    category   => '',
    offset     => 1,
    percentage => 10
};

# These are the apps that are hardcoded to point to a different server pool.
# This list is overwritten by Redis.
our %DIVERT_APP_IDS;
our %DIVERT_CATEGORY = (mt5 => 'mt5');

# These apps are blocked entirely.
# This list is also overwritten by Redis.
our %BLOCK_APP_IDS;
our %BLOCK_ORIGINS;
# These apps are blocked in certain operation domain (red, blue, green etc)
our %APPS_BLOCKED_FROM_OPERATION_DOMAINS;

# Keys are RPC calls that we want RPC to log, controlled by redis too.
our %RPC_LOGGING;

# RPC load controls
our $RPC_THROTTLE = {
    requests_dropped => 0,
    requests_passed  => 0,
    throttle         => 0
};
our $RPC_TIMEOUT_EXTENSION = [RPC_TIMEOUT_DEFAULT];

# API method (action) settings stored in a hash
our $WS_ACTIONS;

# websocket RPC backends
our $WS_BACKENDS;

my $node_config;

#official apps redis set
our %OFFICIAL_APPS;

# a hash of rpc queue configs per environment
our %RPC_ACTIVE_QUEUES;

# feature flag for App Restriction - 3 party apps
my $is_app_restriction_enabled;
my $redis = ws_redis_master();
my $json  = JSON::MaybeXS->new;

=head2 _category_timeout_config

Load configuration file for rpc queue timeouts

=cut

sub _category_timeout_config {
    return YAML::XS::LoadFile('/etc/rmg/rpc_redis_timeouts.yml');
}

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

=head2 get_redis_value_setup

    get_redis_value_setup($key, $log);

Get the value stored in the redis based on the key and apply the value to global variable.

Takes the following arguments

=over 4

=item * C<$key> Redis key example app_id::diverted

=item * C<log> Log object

=back

=cut

sub get_redis_value_setup {
    my ($key, $log) = @_;

    $redis->get(
        $key,
        sub {
            my ($redis, $err, $value) = @_;
            my $key_display = join " ", (split m/::/, $key);
            if ($err) {
                $log->error("Error reading $key_display from Redis: $err");
                return;
            }

            if ($key eq 'rpc::logging') {
                %RPC_LOGGING = $value ? $json->decode(Encode::decode_utf8($value))->%* : ();
                $log->debug("Enabled logging for RPC: " . join(', ', keys %RPC_LOGGING)) if %RPC_LOGGING;
            } else {
                return unless $value;

                $log->debug("Have $key_display applying: $value");

                if ($key eq 'rpc::throttle') {
                    $RPC_THROTTLE->{throttle} = $value;
                } elsif ($key eq 'rpc::timeout_extension') {
                    $RPC_TIMEOUT_EXTENSION = $json->decode(Encode::decode_utf8($value));
                } elsif ($key eq 'app_id::diverted') {
                    %DIVERT_APP_IDS = %{$json->decode(Encode::decode_utf8($value))};
                } elsif ($key eq 'app_id::blocked') {
                    %BLOCK_APP_IDS = %{$json->decode(Encode::decode_utf8($value))};
                } elsif ($key eq 'origins::blocked') {
                    %BLOCK_ORIGINS = %{$json->decode(Encode::decode_utf8($value))};
                } elsif ($key eq 'domain_based_apps::blocked') {
                    update_apps_blocked_from_operation_domain($value);
                } elsif ($key eq 'app_settings::restrict_third_party_apps') {
                    $is_app_restriction_enabled = $value;
                }
            }
        });
}

=head2 backend_setup

    backend_setup($log);

Get the 'web_socket_proxy::backends' value from redis and setup the backends.

Takes the following argument

=over 4

=item * C<$log> Log object

=back

=cut

sub backend_setup {
    my ($log) = @_;
    my $backend_setup_finished = 0;

    $redis->get(
        'web_socket_proxy::backends',
        sub {
            my ($redis, $err, $backends_str) = @_;
            if ($err) {
                $log->error("Error reading backends from master redis: $err");
            }
            if ($backends_str) {
                $log->debug("Found rpc backends in redis, applying.");
                try {
                    my $backends = decode_json_utf8($backends_str);
                    for my $method (keys %$backends) {
                        my $backend = $backends->{$method} // 'default';
                        $backend = 'default' if $backend eq 'rpc_redis';
                        if (exists $WS_ACTIONS->{$method} and ($backend eq 'default' or exists $WS_BACKENDS->{$backend})) {
                            $WS_ACTIONS->{$method}->{backend} = $backend;
                        } else {
                            $log->warn("Invalid  backend setting ignored: <$method $backend>");
                        }
                    }
                    $backend_setup_finished = 1;
                } catch ($e) {
                    $log->error("Error applying backends from master: $e");
                }
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

}

sub startup {
    my $app = shift;
    $app->moniker('websocket');
    $app->plugin('Config' => {file => $ENV{WEBSOCKET_CONFIG} || '/etc/rmg/websocket.conf'});

    my $skip_redis_connection_check = $ENV{WS_SKIP_REDIS_CHECK} // $app->config->{skip_redis_connection_check};

    check_connections() unless $skip_redis_connection_check;    ### Raise and check redis connections

    Mojo::IOLoop->singleton->reactor->on(
        error => sub {
            my (undef, $err) = @_;
            $log->error("EventLoop error: $err");
        });

    $log->debug("Binary.com Websockets API: Starting.");
    $log->debug("Mojolicious Mode is %s", $app->mode);
    $log->debug("Log Level        is %s", $log->adapter->can('level') ? $log->adapter->level : $log->adapter->{log_level});

    apply_usergroup $app->config->{hypnotoad}, sub {
        $log->debug(@_);
    };
    $node_config = YAML::XS::LoadFile('/etc/rmg/node.yml');
    # binary.com plugins
    push @{$app->plugins->namespaces}, 'Binary::WebSocketAPI::Plugins';
    $app->plugin('Introspection' => {port => 0});
    $app->plugin('RateLimits');
    $app->plugin('Longcode');
    $app->plugin('CircuitBreaker');

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

            my $operation_domain = $node_config->{node}->{operation_domain};
            if (first { $app_id == $_ } @{$APPS_BLOCKED_FROM_OPERATION_DOMAINS{$operation_domain // ''}}) {
                return render_access_restriction($c);
            }

            # feature flag check to validate environment restriction for apps
            if ($is_app_restriction_enabled && check_app_restriction($app_id, $operation_domain, $app->config->{third_party_allowed_environments})) {
                return render_access_restriction($c);
            }

            my $request_origin = $c->tx->req->headers->origin // '';
            $request_origin = 'https://' . $request_origin unless $request_origin =~ /^https?:/;
            my $uri = URI->new($request_origin);
            return $c->render(
                json   => {error => 'AccessRestricted'},
                status => 403
            ) if exists $BLOCK_ORIGINS{$uri->host};

            my $client_ip = $c->client_ip;

            my $brand_name = defang($c->req->param('brand'))            // '';
            my $brand      = (first { $_ eq $brand_name } VALID_BRANDS) // DEFAULT_BRAND;

            if ($c->tx and $c->tx->req and $c->tx->req->headers->header('REMOTE_ADDR')) {
                $client_ip = $c->tx->req->headers->header('REMOTE_ADDR');
            }

            my $user_agent = $c->req->headers->header('User-Agent');

            # We'll forward the domain for constructing URLs such as cashier. Note that we are
            # not guaranteed to have referrer information so the stash value may not always
            # be set.
            if (my $domain = $c->req->headers->header('Origin')) {
                my $name = $brand;
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
                brand       => $brand,
                source_type => '',       # Source type will be populated with a first RPC response
            );
        });

    $app->plugin(
        'Mojolicious::Plugin::ClientIP::Pluggable',
        analyze_headers => [qw/cf-pseudo-ipv4 cf-connecting-ip true-client-ip/],
        restrict_family => 'ipv4',
        fallbacks       => [qw/rfc-7239 x-forwarded-for remote_address/]);
    $app->plugin('Binary::WebSocketAPI::Plugins::Helpers');

    my $actions = Binary::WebSocketAPI::Actions::actions_config();

    my $category_timeout_config = _category_timeout_config();
    %RPC_ACTIVE_QUEUES = map { $_ => 1 } @{$app->config->{rpc_active_queues} // []};
    my $backend_rpc_redis = redis_rpc();
    $WS_BACKENDS = {
        rpc_redis => {
            type                    => 'consumer_groups',
            redis                   => $backend_rpc_redis,
            timeout                 => $app->config->{rpc_queue_response_timeout},
            category_timeout_config => $category_timeout_config,
            # we set it 1 all the time as our proxy plugin expects this flag
            # https://github.com/binary-com/perl-Mojo-WebSocketProxy-Backend-ConsumerGroups/blob/b179c239727e036c9e7fca8435cb975cb55f3e0e/lib/Mojo/WebSocketProxy/Backend/ConsumerGroups.pm#L144
            queue_separation_enabled => 1,
        },
    };
    my $app_hooks = {
        before_forward => [
            \&Binary::WebSocketAPI::Hooks::rpc_throttling,           \&Binary::WebSocketAPI::Hooks::start_timing,
            \&Binary::WebSocketAPI::Hooks::start_timing_ws_total,    \&Binary::WebSocketAPI::Hooks::before_forward,
            \&Binary::WebSocketAPI::Hooks::ignore_queue_separations, \&Binary::WebSocketAPI::Hooks::introspection_before_forward,
            \&Binary::WebSocketAPI::Hooks::assign_ws_backend,        \&Binary::WebSocketAPI::Hooks::check_app_id,
            \&Binary::WebSocketAPI::Hooks::rpc_timeout_extension,    \&Binary::WebSocketAPI::Hooks::check_circuit_breaker,
        ],
        before_call => [
            \&Binary::WebSocketAPI::Hooks::log_call_timing_before_forward, \&Binary::WebSocketAPI::Hooks::add_app_id,
            \&Binary::WebSocketAPI::Hooks::add_log_config,                 \&Binary::WebSocketAPI::Hooks::add_brand,
            \&Binary::WebSocketAPI::Hooks::start_timing
        ],
        before_get_rpc_response => [\&Binary::WebSocketAPI::Hooks::log_call_timing],
        after_got_rpc_response  => [
            \&Binary::WebSocketAPI::Hooks::log_call_timing_connection, \&Binary::WebSocketAPI::Hooks::log_response_latency_timing,
            \&Binary::WebSocketAPI::Hooks::error_check
        ],
        before_send_api_response => [
            \&Binary::WebSocketAPI::Hooks::add_req_data,      \&Binary::WebSocketAPI::Hooks::start_timing,
            \&Binary::WebSocketAPI::Hooks::output_validation, \&Binary::WebSocketAPI::Hooks::add_call_debug,
            \&Binary::WebSocketAPI::Hooks::introspection_before_send_response
        ],
        after_sent_api_response =>
            [\&Binary::WebSocketAPI::Hooks::log_call_timing_rpc_sent_and_totalws, \&Binary::WebSocketAPI::Hooks::close_bad_connection],
        after_dispatch => [\&Binary::WebSocketAPI::Hooks::after_dispatch],
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
        push @{$action_options->{stash_params}}, qw(token account_tokens) if $schema_send->{auth_required};

        $WS_ACTIONS->{$action_name} = $action_options;
        if ($action_options->{allow_rest}) {
            $app->routes->any('/websockets/' . $action_name => sub { _rest_rpc($action_name, $app_hooks, @_) });
        }
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
            my $client_id  = $ip . ':' . md5_hex($user_agent);
            return "rate_limits::unauthorised::$app_id/$client_id";
        });

    $app->plugin(
        'web_socket_proxy' => {
            binary_frame => \&Binary::WebSocketAPI::v3::Wrapper::DocumentUpload::document_upload,
            # action hooks
            %$app_hooks,
            # main config
            base_path         => '/websockets/v3',
            stream_timeout    => 120,
            max_connections   => 100000,
            max_response_size => 600000,                                                # change and test this if we ever increase ticks history count
            opened_connection => \&Binary::WebSocketAPI::Hooks::on_client_connect,
            finish_connection => \&Binary::WebSocketAPI::Hooks::on_client_disconnect,
            before_shutdown   => \&Binary::WebSocketAPI::v3::Wrapper::Streamer::send_deploy_notification,

            # helper config
            actions         => $actions,
            backends        => $WS_BACKENDS,
            default_backend => $app->config->{default_backend},
            # Skip check sanity to password fields
            skip_check_sanity => qr/password/,
            rpc_failure_cb    => sub {
                my ($c, $res, $req_storage, $error) = @_;
                if (
                       defined $error
                    && ref $error eq 'HASH'
                    && (
                        !exists $error->{type}
                        || (   $error->{type} ne "Timeout"
                            && $error->{type} ne "WrongResponse")))
                {
                    my $details = 'URL: ' . ($req_storage->{req_url} // 'n/a');
                    if ($error->{code} || $error->{message}) {
                        $details .= ', code: ' . ($error->{code} // 'n/a') . ', response: ' . $error->{message} // 'n/a';
                    }
                    # we don't log WrongResponse and Timeouts as we have metrics for them
                    # this exception should be removed when we have properly
                    # handled CallError
                    my $logger = $req_storage->{logger} // $log;
                    $logger->infof(($error->{type} // 'n/a') . " [" . $req_storage->{msg_type} . "], details: $details");
                }

                DataDog::DogStatsd::Helper::stats_inc(
                    "bom_websocket_api.v_3.rpc.error.count",
                    {
                        tags => [
                            sprintf("rpc:%s",        $req_storage->{method}),
                            sprintf("source:%s",     $c->stash('source')),
                            sprintf("error_type:%s", ($error->{type} // 'UnhandledErrorType')),
                            sprintf(
                                "stream:%s", ($req_storage->{category} // Mojo::WebSocketProxy::Backend::ConsumerGroups::DEFAULT_CATEGORY_NAME()))]});
                return undef;
            },
        });

    get_redis_value_setup('app_id::diverted',                        $log);
    get_redis_value_setup('app_id::blocked',                         $log);
    get_redis_value_setup('origins::blocked',                        $log);
    get_redis_value_setup('domain_based_apps::blocked',              $log);
    get_redis_value_setup('rpc::logging',                            $log);
    get_redis_value_setup('rpc::throttle',                           $log);
    get_redis_value_setup('rpc::timeout_extension',                  $log);
    get_redis_value_setup('app_settings::restrict_third_party_apps', $log);
    load_official_apps_from_redis('domain_based_apps::official', $log);
    backend_setup($log);

    return;
}

=head2 _run_hooks_sync

Given a hook type run the app hooks of that type (this is needed because rest_rpc skips some of the usual hooks).

This is based on the code in cpan/local/lib/perl5/Mojo/WebSocketProxy/Dispatcher.pm for before_send_api response.

=cut

sub _run_hooks_sync {

    my ($type, $c, $req_storage, @other_params) = @_;
    return unless defined($req_storage->{$type});
    my $hooks = $req_storage->{$type};
    $_->($c, $req_storage, @other_params) for grep { $_ } (ref $hooks eq 'ARRAY' ? @{$hooks} : $hooks);
}

=head2 _run_hooks_async

Given a hook type run the app hooks of that type in an async way (this is based on _run_hooks in cpan/local/lib/perl5/Mojo/WebSocketProxy/Dispatcher.pm)

=cut

sub _run_hooks_async {
    my ($type, $c, $req_storage, @other_params) = @_;
    return unless defined($req_storage->{$type});
    my $hooks = $req_storage->{$type};
    use Data::Dumper;

    my $result_f = fmap {
        my $hook   = shift;
        my $result = $hook->($c, $req_storage, @other_params) or return Future->done;
        return $result if blessed($result) && $result->isa('Future');
        return Future->fail($result);
    }
    foreach        => [grep { defined } @$hooks],
        concurrent => 1;
    return $result_f->retain;
}

=head2 _rest_rpc

This methdod is called to handle rest calls to our API endpoints.

=cut

sub _rest_rpc {
    my ($method, $app_hooks, $c) = @_;
    my $rest_consumer_group = $c->wsp_config->{backends}->{default};

    my $args = $c->tx->req->json // {};               # Get the body from the POST request
    if (defined($c->req->param('request_json'))) {    # We allow params in the URL too
        my $more_args = decode_json($c->req->param('request_json'));
        if (ref $more_args eq 'HASH') {
            for my $key (keys %$more_args) { $args->{$key} = $more_args->{$key}; }
        }
    }

    $args->{$method} = 1;                             #Even if this was passed as an arg, overwrite it to avoid inconsistencies

    my $req_storage = {
        method       => $method,
        args         => $args,
        stash_params => $WS_ACTIONS->{$method}->{stash_params},
        name         => $WS_ACTIONS->{$method}->{name},
        schema_send  => $WS_ACTIONS->{$method}->{schema_send},
        # action hooks
        %$app_hooks,

    };

    $req_storage->{rpc_failure_cb} = sub {
        my ($error) = @_;
        $c->render(
            json => {error => $error},
        );
    };

    $req_storage->{send_func} = sub {
        my ($message) = @_;
        my $api_response = $message->{'json'};
        _run_hooks_sync('before_send_api_response', $c, $req_storage, $api_response);
        $c->render(
            json => $api_response,
        );
        _run_hooks_sync('after_sent_api_response', $c, $req_storage, $api_response);
    };

    #Call the RPC
    try {
        _run_hooks_async('before_forward', $c, $req_storage)->get();    #Wait for the before_forward hooks to run, and throw failure as exceptions
    } catch ($e) {
        $c->render(
            json   => $e,
            status => '400',
        );
        return;
    }

    $rest_consumer_group->call_rpc($c, $req_storage);
    _run_hooks_async('after_dispatch', $c, $req_storage)->on_fail(
        sub {
            $c->app->log->error("An error occurred handling on_message. Error @_");
        })->retain;

    return;

}

=head2 update_apps_blocked_from_operation_domain

    update_apps_blocked_from_operation_domain($apps_blocked_json);

Update the global variable APPS_BLOCKED_FROM_OPERATION_DOMAINS from given JSON value.
Note: Wrapped the global variable setting in the function.

=cut

sub update_apps_blocked_from_operation_domain {
    my ($apps_blocked_json) = @_;
    my $json = JSON::MaybeXS->new;
    %APPS_BLOCKED_FROM_OPERATION_DOMAINS = %{$json->decode($apps_blocked_json)};
}

=head2 add_remove_apps_blocked_from_opertion_domain

    add_remove_apps_blocked_from_opertion_domain($operation, $app_id, $domain);

Add (block) or remove (unblock) the app ids from APPS_BLOCKED_FROM_OPERATION_DOMAINS.
Note: This is also a wrapper to update the global variable based on block or unblock request from Introspection command.

Taking the following arguments and returns future.

=over 4

=item * C<$operation> add or delete

=item * C<$app_id> app_id

=item * C<$domain> red/blue/green etc operation domain

=back

=cut

sub add_remove_apps_blocked_from_opertion_domain {
    my ($operation, $app_id, $domain) = @_;

    my $f = Future::Mojo->new;
    if ($operation eq 'add') {
        push $APPS_BLOCKED_FROM_OPERATION_DOMAINS{$domain}->@*, $app_id;
    } elsif ($operation eq 'del') {
        $APPS_BLOCKED_FROM_OPERATION_DOMAINS{$domain} = [grep { $_ != $app_id } $APPS_BLOCKED_FROM_OPERATION_DOMAINS{$domain}->@*];
    }

    set_to_redis_master(
        'domain_based_apps::blocked',
        Encode::encode_utf8($json->encode(\%Binary::WebSocketAPI::APPS_BLOCKED_FROM_OPERATION_DOMAINS)),
        sub {
            my ($redis, $err) = @_;
            if ($err) {
                $f->fail($err);
                $log->error("Error setting domain_based_apps::blocked redis value: $err");
                return;
            }
            $f->done();
            return;
        });
    return $f;
}

=head2 get_apps_blocked_from_operation_domain

Get value stored in the global variable Binary::WebSocketAPI::APPS_BLOCKED_FROM_OPERATION_DOMAINS and returns future.

=cut

sub get_apps_blocked_from_operation_domain {
    my $f = Future::Mojo->new;
    get_from_redis_master(
        'domain_based_apps::blocked',
        sub {
            my ($redis, $err, $apps_blocked) = @_;
            $apps_blocked //= '{}';
            if ($err) {
                $log->error("Error reading domain_based_apps::blocked redis value: $err");
                $f->fail($err);
                return;
            }
            update_apps_blocked_from_operation_domain($apps_blocked);
            $f->done(\%Binary::WebSocketAPI::APPS_BLOCKED_FROM_OPERATION_DOMAINS);
            return;
        });
    return $f;
}

=head2 get_from_redis_master

    get_from_redis_master($key, $cb);

Get key value from redis master

It takes the following argument

=over 4

=item * C<key> Key

=item * C<cb> Callback

=back

=cut

sub get_from_redis_master {
    my ($key, $cb) = @_;
    $redis->get($key, $cb);
}

=head2 set_to_redis_master

    set_to_redis_master($key, $value, $cb);

Set value to redis master

The following arguments are used

=over 4

=item * C<key> Key example domain_based_apps::blocked

=item * C<value> Value

=item * C<cb> Callback

=back

=cut

sub set_to_redis_master {
    my ($key, $value, $cb) = @_;
    $redis->set(
        $key => $value,
        $cb
    );
}

=head2 load_official_apps_from_redis

the function will fetch official app list from redis

=cut

sub load_official_apps_from_redis {
    my $key = shift;
    my $f   = Future::Mojo->new;

    $redis->smembers(
        $key,
        sub {
            my ($redis, $err, $official_apps) = @_;

            if ($err) {
                $log->error("Error reading domain_based_apps::official redis value: $err");
                $f->fail($err);
                return;
            }

            %OFFICIAL_APPS = map { $_ => 1 } @{$official_apps || []};

            if (!%OFFICIAL_APPS) {
                $log->warn("Empty or undefined set for domain_based_apps::official in Redis");
            }

            $f->done(\%OFFICIAL_APPS);
        });

    return $f;
}

=head2 is_app_official

the function will check app_id is in official app list

The following arguments are used

=over 4

=item * C<app_id> app_id 

=back

=cut

sub is_app_official {
    my $app_id = shift;
    return 1 if !%OFFICIAL_APPS;    # do not restrict access in case hash is empty or undefined
    return exists $OFFICIAL_APPS{$app_id};
}

=head2 check_app_restriction

the function will manage app restriction for 3 party apps (non official) against allowed environments

The following arguments are used

=over 4

=item * C<app_id> app_id 

=item * C<operation_domain> operation_domain 

=item * C<third_party_environments> third_party_environments 

=back

=cut

sub check_app_restriction {
    my ($app_id, $operation_domain, $third_party_environments) = @_;
    my $is_official_app = is_app_official($app_id);
    return 0 if $is_official_app;
    return 1 if (!grep { $_ eq $operation_domain } @$third_party_environments);
    return 0;
}

=head2 render_access_restriction

The function will render AccessRestricted error with 403 status code

=cut

sub render_access_restriction {
    my $c = shift;
    return $c->render(
        json   => {error => 'AccessRestricted'},
        status => 403
    );
}

1;
