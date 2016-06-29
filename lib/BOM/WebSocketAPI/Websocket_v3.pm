package BOM::WebSocketAPI::Websocket_v3;

use Mojo::Base 'Mojolicious::Controller';
use MojoX::JSON::RPC::Client;
use DataDog::DogStatsd::Helper;
use JSON::Schema;
use File::Slurp;
use JSON;
use Time::HiRes;
use Data::UUID;
use Time::Out qw(timeout);
use Guard;
use feature "state";
use RateLimitations qw(within_rate_limits);

use BOM::WebSocketAPI::v3::Wrapper::Streamer;
use BOM::WebSocketAPI::v3::Wrapper::Transaction;
use BOM::WebSocketAPI::v3::Wrapper::Authorize;
use BOM::WebSocketAPI::v3::Wrapper::System;
use BOM::WebSocketAPI::v3::Wrapper::Accounts;
use BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery;
use BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement;
use BOM::WebSocketAPI::v3::Wrapper::Cashier;
use BOM::WebSocketAPI::v3::Wrapper::NewAccount;
use BOM::Database::Rose::DB;
use BOM::WebSocketAPI::v3::Wrapper::Pricer;

sub ok {
    my $c = shift;
    return 1;
}

sub entry_point {
    my $c = shift;

    my $log = $c->app->log;
    $log->debug("opening a websocket for " . $c->tx->remote_address);

    # enable permessage-deflate
    $c->tx->with_compression;

    # Increase inactivity timeout for connection a bit
    Mojo::IOLoop->singleton->stream($c->tx->connection)->timeout(120);
    Mojo::IOLoop->singleton->max_connections(100000);

    if (not $c->stash->{redis_pricer}) {
        state $url_pricers = do {
            my $cf = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml')->{write};
            my $url = Mojo::URL->new("redis://$cf->{host}:$cf->{port}");
            $url->userinfo('dummy:' . $cf->{password}) if $cf->{password};
            $url;
        };

        my $redis_pricer = Mojo::Redis2->new(url => $url_pricers);
        $redis_pricer->on(
            error => sub {
                my ($self, $err) = @_;
                warn("error: $err");
            });
        $redis_pricer->on(
            message => sub {
                my ($self, $msg, $channel) = @_;
                BOM::WebSocketAPI::v3::Wrapper::Pricer::process_pricing_events($c, $msg, $channel);
            });
        $c->stash->{redis_pricer} = $redis_pricer;
    }

    if (not $c->stash->{redis}) {
        state $url = do {
            my $cf = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/chronicle.yml')->{read};
            defined($cf->{password})
                ? "redis://dummy:$cf->{password}\@$cf->{host}:$cf->{port}"
                : "redis://$cf->{host}:$cf->{port}";
        };

        my $redis = Mojo::Redis2->new(url => $url);
        $redis->on(
            error => sub {
                my ($self, $err) = @_;
                warn("error: $err");
            });
        $redis->on(
            message => sub {
                my ($self, $msg, $channel) = @_;

                BOM::WebSocketAPI::v3::Wrapper::Streamer::process_realtime_events($c, $msg, $channel)
                    if $channel =~ /^(?:FEED|PricingTable)::/;
                BOM::WebSocketAPI::v3::Wrapper::Streamer::process_transaction_updates($c, $msg)
                    if $channel =~ /^TXNUPDATE::transaction_/;
            });
        $c->stash->{redis} = $redis;
    }

    $c->on(
        json => sub {
            my ($c, $p1) = @_;

            my $tag = 'origin:';
            my $data;
            my $send = 1;
            if (ref($p1) eq 'HASH') {

                if (my $origin = $c->req->headers->header("Origin")) {
                    if ($origin =~ /https?:\/\/([a-zA-Z0-9\.]+)$/) {
                        $tag = "origin:$1";
                    }
                }

                $c->stash('args' => $p1);

                timeout 15 => sub {
                    $data = _sanity_failed($c, $p1) || __handle($c, $p1, $tag);
                };
                if ($@) {
                    $c->app->log->info("$$ timeout for " . JSON::to_json($p1));
                }

                if (not $data) {
                    $send = undef;
                    $data = {};
                }

                if (    $data->{error}
                    and $data->{error}->{code} eq 'SanityCheckFailed')
                {
                    $data->{echo_req} = {};
                } else {
                    $data->{echo_req} = $p1;
                }
                $data->{req_id} = $p1->{req_id} if (exists $p1->{req_id});
            } else {
                # for invalid call, eg: not json
                $data = $c->new_error('error', 'BadRequest', $c->l('The application sent an invalid request.'));
                $data->{echo_req} = {};
            }

            my $l = length JSON::to_json($data);
            if ($l > 328000) {
                $data = $c->new_error('error', 'ResponseTooLarge', $c->l('Response too large.'));
                $data->{echo_req} = $p1;
                $data->{req_id} = $p1->{req_id} if (exists $p1->{req_id});
            }
            if ($send) {
                $c->send({json => $data});
            }

            BOM::Database::Rose::DB->db_cache->finish_request_cycle;
            return;
        });

    # stop all recurring
    $c->on(
        finish => sub {
            my $c = shift;
            BOM::WebSocketAPI::v3::Wrapper::System::forget_all($c, {forget_all => 1});
            delete $c->stash->{redis};
            delete $c->stash->{redis_pricer};
        });

    return;
}

# [param key, sub, require auth]
my @dispatch = (
    ['authorize', '', 0, '', {stash_params => [qw/ ua_fingerprint /]}],
    [
        'logout', '', 0, '',
        {
            stash_params => [qw/ token token_type email client_ip country_code user_agent /],
            success      => \&BOM::WebSocketAPI::v3::Wrapper::Authorize::logout_success,
        },
    ],
    ['trading_times', '', 0],
    [
        'asset_index',
        '', 0, '',
        {
            before_forward => \&BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery::asset_index_cached,
            success        => \&BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery::cache_asset_index,
        }
    ],
    ['active_symbols',          '',                                                        0, '', {stash_params => [qw/ token /]}],
    ['ticks',                   \&BOM::WebSocketAPI::v3::Wrapper::Streamer::ticks,         0],
    ['ticks_history',           \&BOM::WebSocketAPI::v3::Wrapper::Streamer::ticks_history, 0],
    ['proposal',                \&BOM::WebSocketAPI::v3::Wrapper::Pricer::proposal,        0],
    ['pricing_table',           \&BOM::WebSocketAPI::v3::Wrapper::Streamer::pricing_table, 0],
    ['forget',                  \&BOM::WebSocketAPI::v3::Wrapper::System::forget,          0],
    ['forget_all',              \&BOM::WebSocketAPI::v3::Wrapper::System::forget_all,      0],
    ['ping',                    \&BOM::WebSocketAPI::v3::Wrapper::System::ping,            0],
    ['time',                    \&BOM::WebSocketAPI::v3::Wrapper::System::server_time,     0],
    ['website_status',          '',                                                        0, '', {stash_params => [qw/ country_code /]}],
    ['contracts_for',           '',                                                        0],
    ['residence_list',          '',                                                        0],
    ['states_list',             '',                                                        0],
    ['payout_currencies',       '',                                                        0, '', {stash_params => [qw/ token /]}],
    ['landing_company',         '',                                                        0],
    ['landing_company_details', '',                                                        0],
    ['get_corporate_actions',   '',                                                        0],

    [
        'balance',
        '', 1, 'read',
        {
            before_forward => \&BOM::WebSocketAPI::v3::Wrapper::Accounts::subscribe_transaction_channel,
            error          => \&BOM::WebSocketAPI::v3::Wrapper::Accounts::balance_error_handler,
            success        => \&BOM::WebSocketAPI::v3::Wrapper::Accounts::balance_success_handler,
        }
    ],

    ['statement',          '', 1, 'read'],
    ['profit_table',       '', 1, 'read'],
    ['get_account_status', '', 1, 'read'],
    ['change_password',    '', 1, 'admin',    {stash_params => [qw/ token_type client_ip /]}],
    ['get_settings',       '', 1, 'read'],
    ['set_settings',       '', 1, 'admin',    {stash_params => [qw/ server_name client_ip user_agent /]}],
    ['get_self_exclusion', '', 1, 'read'],
    ['set_self_exclusion', '', 1, 'admin',    {response     => \&BOM::WebSocketAPI::v3::Wrapper::Accounts::set_self_exclusion_response_handler}],
    ['cashier_password',   '', 1, 'payments', {stash_params => [qw/ client_ip /]}],

    ['api_token',            '', 1, 'admin', {stash_params     => [qw/ account_id /]}],
    ['tnc_approval',         '', 1, 'admin'],
    ['login_history',        '', 1, 'read',  {response         => \&BOM::WebSocketAPI::v3::Wrapper::Accounts::login_history_response_handler}],
    ['set_account_currency', '', 1, 'admin', {make_call_params => \&BOM::WebSocketAPI::v3::Wrapper::Accounts::set_account_currency_params_handler}],
    ['set_financial_assessment', '', 1, 'admin'],
    ['get_financial_assessment', '', 1, 'admin'],
    ['reality_check',            '', 1, 'read'],

    [
        'verify_email',
        '', 0, '',
        {
            before_call  => [\&BOM::WebSocketAPI::v3::Wrapper::NewAccount::verify_email_get_type_code],
            stash_params => [qw/ server_name /],
        }
    ],
    ['new_account_virtual', '', 0, '', {stash_params => [qw/ server_name client_ip user_agent /]}],
    ['reset_password',      '', 0],

    # authenticated calls
    ['sell', '', 1, 'trade'],
    [
        'buy', '', 1, 'trade',
        {
            stash_params   => [qw/ app_markup_percentage /],
            before_forward => \&BOM::WebSocketAPI::v3::Wrapper::Transaction::buy_get_contract_params,
        }
    ],
    ['transaction', '', 1, 'read', {before_forward => \&BOM::WebSocketAPI::v3::Wrapper::Transaction::transaction}],
    ['portfolio',   '', 1, 'read'],
    ['proposal_open_contract', \&BOM::WebSocketAPI::v3::Wrapper::Pricer::proposal_open_contract, 1, 'read', {stash_params => [qw/ app_markup_percentage /],}],
    [
        'proposal_open_contract_orig',
        '', 1, 'read',
        {
            stash_params    => [qw/ app_markup_percentage /],
            rpc_response_cb => \&BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement::proposal_open_contract,
        }
    ],
    ['sell_expired', '', 1, 'trade'],

    ['app_register', '', 1, 'admin'],
    ['app_list',     '', 1, 'admin'],
    ['app_get',      '', 1, 'admin'],
    ['app_update',   '', 1, 'admin'],
    ['app_delete',   '', 1, 'admin'],
    ['oauth_apps',   '', 1, 'admin'],

    ['topup_virtual', '', 1, 'trade'],
    ['get_limits',    '', 1, 'read'],
    ['paymentagent_list', '', 0, '', {stash_params => [qw/ token /]}],
    [
        'paymentagent_withdraw',
        '', 1,
        'payments',
        {
            error        => \&BOM::WebSocketAPI::v3::Wrapper::Cashier::log_paymentagent_error,
            response     => BOM::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('paymentagent_withdraw'),
            stash_params => [qw/ server_name /],
        }
    ],
    [
        'paymentagent_transfer',
        '', 1,
        'payments',
        {
            error        => \&BOM::WebSocketAPI::v3::Wrapper::Cashier::log_paymentagent_error,
            response     => BOM::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('paymentagent_transfer'),
            stash_params => [qw/ server_name /],
        }
    ],
    [
        'transfer_between_accounts',
        '', 1,
        'payments',
        {
            error    => \&BOM::WebSocketAPI::v3::Wrapper::Cashier::log_paymentagent_error,
            response => BOM::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('transfer_between_accounts'),
        }
    ],
    ['cashier', '', 1, 'payments'],
    ['new_account_real',        '', 1, 'admin', {stash_params => [qw/ server_name client_ip user_agent /]}],
    ['new_account_japan',       '', 1, 'admin', {stash_params => [qw/ server_name client_ip user_agent /]}],
    ['new_account_maltainvest', '', 1, 'admin', {stash_params => [qw/ server_name client_ip user_agent /]}],
    ['jp_knowledge_test',       '', 1, 'admin', {stash_params => [qw/ server_name client_ip user_agent /]}],
);

# key: category, value:  hashref (descriptor) with fields
#   - category      (string)
#   - handler       (coderef)
#   - require_auth  (flag)
#   - order         (integer)
#   - in_validator  (JSON::Schema)
#   - out_validator (JSON::Schema)
#   - require_scope (string)

my %dispatch_handler_for;
for my $order (0 .. @dispatch - 1) {
    my $dispatch      = $dispatch[$order];
    my $category      = $dispatch->[0];
    my $f             = '/home/git/regentmarkets/bom-websocket-api/config/v3/' . $category;
    my $in_validator  = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/send.json")), format => \%JSON::Schema::FORMATS);
    my $out_validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/receive.json")), format => \%JSON::Schema::FORMATS);
    $dispatch_handler_for{$category} = {
        category       => $category,
        order          => $order,
        handler        => $dispatch->[1],
        require_auth   => $dispatch->[2],
        out_validator  => $out_validator,
        in_validator   => $in_validator,
        require_scope  => $dispatch->[3],
        forward_params => $dispatch->[4],
    };
}

my %rate_limit_map = (
    ping_real                      => '',
    time_real                      => '',
    portfolio_real                 => 'websocket_call_expensive',
    statement_real                 => 'websocket_call_expensive',
    profit_table_real              => 'websocket_call_expensive',
    proposal_real                  => 'websocket_real_pricing',
    pricing_table_real             => 'websocket_real_pricing',
    proposal_open_contract_real    => 'websocket_real_pricing',
    verify_email_real              => 'websocket_call_email',
    buy_real                       => 'websocket_real_pricing',
    sell_real                      => 'websocket_real_pricing',
    reality_check_real             => 'websocket_call_expensive',
    ping_virtual                   => '',
    time_virtual                   => '',
    portfolio_virtual              => 'websocket_call_expensive',
    statement_virtual              => 'websocket_call_expensive',
    profit_table_virtual           => 'websocket_call_expensive',
    proposal_virtual               => 'websocket_call_pricing',
    pricing_table_virtual          => 'websocket_call_pricing',
    proposal_open_contract_virtual => 'websocket_call_pricing',
    verify_email_virtual           => 'websocket_call_email',
);

sub _reached_limit_check {
    my ($connection_id, $category, $is_real) = @_;

    my $limiting_service = $rate_limit_map{
        $category . '_'
            . (
            ($is_real)
            ? 'real'
            : 'virtual'
            )} // 'websocket_call';
    if (
        $limiting_service
        and not within_rate_limits({
                service  => $limiting_service,
                consumer => $connection_id,
            }))
    {
        return 1;
    }
    return;
}

# Set JSON Schema default values for fields which are missing and have default.
sub _set_defaults {
    my ($validator, $args) = @_;

    my $properties = $validator->{in_validator}->schema->{properties};

    foreach my $k (keys %$properties) {
        $args->{$k} = $properties->{$k}->{default} if not exists $args->{$k} and $properties->{$k}->{default};
    }
    return;
}

sub __handle {
    my ($c, $p1, $tag) = @_;

    my $log = $c->app->log;
    $log->debug("websocket got json " . $c->dumper($p1));

    my @handler_descriptors =
        sort { $a->{order} <=> $b->{order} }
        grep { defined }
        map  { $dispatch_handler_for{$_} } keys $p1;
    for my $descriptor (@handler_descriptors) {

        if (not $c->stash('connection_id')) {
            $c->stash('connection_id' => Data::UUID->new()->create_str());
        }

        my $t0 = [Time::HiRes::gettimeofday];

        # For authorized calls that are heavier we will limit based on loginid
        # For unauthorized calls that are less heavy we will use connection id.
        # None are much helpful in a well prepared DDoS.
        my $consumer = $c->stash('loginid') || $c->stash('connection_id');

        if (_reached_limit_check($consumer, $descriptor->{category}, $c->stash('loginid') && !$c->stash('is_virtual'))) {
            return $c->new_error($descriptor->{category}, 'RateLimit', $c->l('You have reached the rate limit for [_1].', $descriptor->{category}));
        }

        my $input_validation_result = $descriptor->{in_validator}->validate($p1);
        if (not $input_validation_result) {
            my ($details, @general);
            foreach my $err ($input_validation_result->errors) {
                if ($err->property =~ /\$\.(.+)$/) {
                    $details->{$1} = $err->message;
                } else {
                    push @general, $err->message;
                }
            }
            my $message = $c->l('Input validation failed: ') . join(', ', (keys %$details, @general));
            return $c->new_error($descriptor->{category}, 'InputValidationFailed', $message, $details);
        }

        _set_defaults($descriptor, $p1);

        DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.call.' . $descriptor->{category}, {tags => [$tag]});
        DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.call.all', {tags => [$tag, "category:$descriptor->{category}"]});

        my $loginid = $c->stash('loginid');
        if ($descriptor->{require_auth} and not $loginid) {
            return $c->new_error($descriptor->{category}, 'AuthorizationRequired', $c->l('Please log in.'));
        }

        if ($descriptor->{require_scope} and not(grep { $_ eq $descriptor->{require_scope} } @{$c->stash('scopes') || []})) {
            return $c->new_error($descriptor->{category},
                'PermissionDenied', $c->l('Permission denied, requires [_1] scope.', $descriptor->{require_scope}));
        }

        if ($loginid) {
            my $account_type = $c->stash('is_virtual') ? 'virtual' : 'real';
            DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.authenticated_call.all',
                {tags => [$tag, $descriptor->{category}, "account_type:$account_type"]});
        }

        my $result;
        if (my $handler = $descriptor->{handler}) {
            $result = $handler->($c, $p1, {require_auth => $descriptor->{require_auth}});
        } else {
            my %forward_params;
            if (ref $descriptor->{forward_params} eq 'HASH') {
                %forward_params = %{$descriptor->{forward_params}};
            }

            # Don't forward call to RPC if there is result
            my $before_forward = delete $forward_params{before_forward};
            $result = $before_forward->($c, $p1, \%forward_params) if $before_forward;

            unless ($result) {
                # TODO New dispatcher plugin has to do this
                my $url = $ENV{RPC_URL} || 'http://127.0.0.1:5005/';
                if (BOM::System::Config::env eq 'production') {
                    if (BOM::System::Config::node->{node}->{www2}) {
                        $url = 'http://internal-rpc-www2-703689754.us-east-1.elb.amazonaws.com:5005/';
                    } else {
                        $url = 'http://internal-rpc-1484966228.us-east-1.elb.amazonaws.com:5005/';
                    }
                }

                $forward_params{before_call}              = [@{$forward_params{before_call}              || []}, \&start_timing];
                $forward_params{before_get_rpc_response}  = [@{$forward_params{before_get_rpc_response}  || []}, \&log_call_timing];
                $forward_params{after_got_rpc_response}   = [@{$forward_params{after_got_rpc_response}   || []}, \&log_call_timing_connection];
                $forward_params{before_send_api_response} = [@{$forward_params{before_send_api_response} || []}, \&add_debug_time, \&start_timing];
                $forward_params{after_sent_api_response}  = [@{$forward_params{after_sent_api_response}  || []}, \&log_call_timing_sent];

                # No need return result because always do async response
                my $method = $descriptor->{category};
                BOM::WebSocketAPI::CallingEngine::forward(
                    $c, $url, $method, $p1,
                    {
                        require_auth => $descriptor->{require_auth},
                        %forward_params,
                    });
            }
        }

        if ($result) {
            my $output_validation_result = $descriptor->{out_validator}->validate($result);
            if (not $output_validation_result) {
                my $error = join(" - ", $output_validation_result->errors);
                $log->warn("Invalid output parameter for [ " . JSON::to_json($result) . " error: $error ]");
                return $c->new_error($descriptor->{category}, 'OutputValidationFailed', $c->l("Output validation failed: ") . $error);
            }
        }
        if (ref($result) && $c->stash('debug')) {
            $result->{debug} = {
                time   => 1000 * Time::HiRes::tv_interval($t0),
                method => $descriptor->{category},
            };
        }
        return $result;
    }

    $log->debug("unrecognised request: " . $c->dumper($p1));
    return $c->new_error('error', 'UnrecognisedRequest', $c->l('Unrecognised request.'));
}

sub _failed_key_value {
    my ($key, $value) = @_;

    state $pwd_field = {map { $_ => 1 } qw( client_password old_password new_password unlock_password lock_password )};

    if ($pwd_field->{$key}) {
        return;
    } elsif (
        $key !~ /^[A-Za-z0-9_-]{1,50}$/
        # !-~ to allow a range of acceptable characters. To find what is the range, look at ascii table

        # please don't remove: \p{Script=Common}\p{L}
        # \p{L} is to match utf-8 characters
        # \p{Script=Common} is to match double byte characters in Japanese keyboards, eg: '１−１−１'
        # refer: http://perldoc.perl.org/perlunicode.html
        # null-values are allowed
        or ($value and $value !~ /^[\p{Script=Common}\p{L}\s\w\@_:!-~]{0,300}$/))
    {
        return ($key, $value);
    }
    return;
}

sub rpc {
    my $c               = shift;
    my $method          = shift;
    my $rpc_response_cb = shift;
    my $params          = shift;
    my $method_name     = shift;

    # TODO New dispatcher plugin has to do this
    my $url = $ENV{RPC_URL} || 'http://127.0.0.1:5005/';
    if (BOM::System::Config::env eq 'production') {
        if (BOM::System::Config::node->{node}->{www2}) {
            $url = 'http://internal-rpc-www2-703689754.us-east-1.elb.amazonaws.com:5005/';
        } else {
            $url = 'http://internal-rpc-1484966228.us-east-1.elb.amazonaws.com:5005/';
        }
    }
    $url .= $method;

    $params->{language}              = $c->stash('language');
    $params->{country}               = $c->stash('country') || $c->country_code;
    $params->{source}                = $c->stash('source');
    $params->{app_markup_percentage} = $c->stash('app_markup_percentage');

    BOM::WebSocketAPI::CallingEngine::call_rpc(
        $c,
        {
            method                   => $method,
            msg_type                 => $method_name // $method,
            url                      => $url,
            call_params              => $params,
            rpc_response_cb          => $rpc_response_cb,
            before_call              => [\&start_timing],
            before_get_rpc_response  => [\&log_call_timing],
            after_got_rpc_response   => [\&log_call_timing_connection],
            before_send_api_response => [\&add_debug_time, \&start_timing],
            after_sent_api_response  => [\&log_call_timing_sent],
        },
    );
    return;
}

sub _sanity_failed {
    my ($c, $arg) = @_;
    my @failed;

    OUTER:
    foreach my $k (keys %$arg) {
        if (not ref $arg->{$k}) {
            last OUTER if (@failed = _failed_key_value($k, $arg->{$k}));
        } else {
            if (ref $arg->{$k} eq 'HASH') {
                foreach my $l (keys %{$arg->{$k}}) {
                    last OUTER
                        if (@failed = _failed_key_value($l, $arg->{$k}->{$l}));
                }
            } elsif (ref $arg->{$k} eq 'ARRAY') {
                foreach my $l (@{$arg->{$k}}) {
                    last OUTER if (@failed = _failed_key_value($k, $l));
                }
            }
        }
    }

    if (@failed) {
        $c->app->log->warn("Sanity check failed: " . $failed[0] . " -> " . ($failed[1] // "undefined"));
        return $c->new_error('sanity_check', 'SanityCheckFailed', $c->l("Parameters sanity check failed."));
    }
    return;
}

sub start_timing {
    my ($c, $params) = @_;
    $params->{tv} = [Time::HiRes::gettimeofday];
    return;
}

sub log_call_timing {
    my ($c, $params) = @_;
    DataDog::DogStatsd::Helper::stats_timing(
        'bom_websocket_api.v_3.rpc.call.timing',
        1000 * Time::HiRes::tv_interval($params->{tv}),
        {tags => ["rpc:$params->{method}"]});
    my $app_name = $c->stash('app_name') || '';
    DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.rpc.call.count', {tags => ["rpc:$params->{method}", "app_name:$app_name"]});
    return;
}

sub log_call_timing_connection {
    my ($c, $params, $rpc_response) = @_;
    if (ref($rpc_response->result) eq "HASH"
        && (my $rpc_time = delete $rpc_response->result->{rpc_time}))
    {
        DataDog::DogStatsd::Helper::stats_timing(
            'bom_websocket_api.v_3.rpc.call.timing.connection',
            1000 * Time::HiRes::tv_interval($params->{tv}) - $rpc_time,
            {tags => ["rpc:$params->{method}"]});
    }
    return;
}

sub add_debug_time {
    my ($c, $params, $api_response) = @_;
    if ($c->stash('debug')) {
        $api_response->{debug} = {
            time   => 1000 * Time::HiRes::tv_interval($params->{tv}),
            method => $params->{method},
        };
    }
    return;
}

sub log_call_timing_sent {
    my ($c, $params) = @_;
    DataDog::DogStatsd::Helper::stats_timing(
        'bom_websocket_api.v_3.rpc.call.timing.sent',
        1000 * Time::HiRes::tv_interval($params->{tv}),
        {tags => ["rpc:$params->{method}"]});
    return;
}

1;
