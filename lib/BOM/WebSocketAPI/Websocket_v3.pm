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
use Proc::CPUUsage;
use feature "state";
use RateLimitations qw(within_rate_limits);

use BOM::WebSocketAPI::v3::Wrapper::Streamer;
use BOM::WebSocketAPI::v3::Wrapper::Transaction;
use BOM::WebSocketAPI::v3::Wrapper::Offerings;
use BOM::WebSocketAPI::v3::Wrapper::Authorize;
use BOM::WebSocketAPI::v3::Wrapper::System;
use BOM::WebSocketAPI::v3::Wrapper::Accounts;
use BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery;
use BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement;
use BOM::WebSocketAPI::v3::Wrapper::Static;
use BOM::WebSocketAPI::v3::Wrapper::Cashier;
use BOM::WebSocketAPI::v3::Wrapper::NewAccount;
use BOM::WebSocketAPI::v3::Wrapper::App;
use BOM::Database::Rose::DB;

sub ok {
    my $c      = shift;
    my $source = 1;       # check http origin here
    $c->stash(source => $source);
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

    if (not $c->stash->{redis}) {
        state $url = do {
            my $cf = YAML::XS::LoadFile('/etc/rmg/chronicle.yml')->{read};
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

                # set correct request context for localize
                BOM::Platform::Context::request($c->stash('request'))
                    if $channel =~ /^FEED::/;
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

            BOM::Platform::Context::request($c->stash('request'));

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
        });

    return;
}

# [param key, sub, require auth]
my @dispatch = (
    ['authorize', \&BOM::WebSocketAPI::v3::Wrapper::Authorize::authorize, 0],
    ['logout',    \&BOM::WebSocketAPI::v3::Wrapper::Authorize::logout,    0],
    [
        'trading_times',
        \&BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery::trading_times, 0
    ],
    [
        'asset_index',
        \&BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery::asset_index, 0
    ],
    [
        'active_symbols',
        \&BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery::active_symbols, 0
    ],
    ['ticks', \&BOM::WebSocketAPI::v3::Wrapper::Streamer::ticks, 0],
    [
        'ticks_history',
        \&BOM::WebSocketAPI::v3::Wrapper::Streamer::ticks_history, 0
    ],
    ['proposal',       \&BOM::WebSocketAPI::v3::Wrapper::Streamer::proposal,      0],
    ['pricing_table',  \&BOM::WebSocketAPI::v3::Wrapper::Streamer::pricing_table, 0],
    ['forget',         \&BOM::WebSocketAPI::v3::Wrapper::System::forget,          0],
    ['forget_all',     \&BOM::WebSocketAPI::v3::Wrapper::System::forget_all,      0],
    ['ping',           \&BOM::WebSocketAPI::v3::Wrapper::System::ping,            0],
    ['time',           \&BOM::WebSocketAPI::v3::Wrapper::System::server_time,     0],
    ['website_status', \&BOM::WebSocketAPI::v3::Wrapper::System::website_status,  0],
    [
        'contracts_for',
        \&BOM::WebSocketAPI::v3::Wrapper::Offerings::contracts_for, 0
    ],
    [
        'residence_list',
        \&BOM::WebSocketAPI::v3::Wrapper::Static::residence_list, 0
    ],
    ['states_list', \&BOM::WebSocketAPI::v3::Wrapper::Static::states_list, 0],
    [
        'payout_currencies',
        \&BOM::WebSocketAPI::v3::Wrapper::Accounts::payout_currencies, 0
    ],
    [
        'landing_company',
        \&BOM::WebSocketAPI::v3::Wrapper::Accounts::landing_company, 0
    ],
    [
        'landing_company_details',
        \&BOM::WebSocketAPI::v3::Wrapper::Accounts::landing_company_details, 0
    ],

    ['balance',   \&BOM::WebSocketAPI::v3::Wrapper::Accounts::balance,   1, 'read'],
    ['statement', \&BOM::WebSocketAPI::v3::Wrapper::Accounts::statement, 1, 'read'],
    [
        'profit_table',
        \&BOM::WebSocketAPI::v3::Wrapper::Accounts::profit_table, 1, 'read'
    ],
    [
        'get_account_status',
        \&BOM::WebSocketAPI::v3::Wrapper::Accounts::get_account_status, 1, 'read'
    ],
    [
        'change_password',
        \&BOM::WebSocketAPI::v3::Wrapper::Accounts::change_password, 1, 'admin'
    ],
    [
        'get_settings',
        \&BOM::WebSocketAPI::v3::Wrapper::Accounts::get_settings, 1, 'read'
    ],
    [
        'set_settings',
        \&BOM::WebSocketAPI::v3::Wrapper::Accounts::set_settings, 1, 'admin'
    ],
    [
        'get_self_exclusion',
        \&BOM::WebSocketAPI::v3::Wrapper::Accounts::get_self_exclusion, 1, 'read'
    ],
    [
        'set_self_exclusion',
        \&BOM::WebSocketAPI::v3::Wrapper::Accounts::set_self_exclusion, 1, 'admin'
    ],
    [
        'cashier_password',
        \&BOM::WebSocketAPI::v3::Wrapper::Accounts::cashier_password, 1, 'payments'
    ],

    ['api_token',                \&BOM::WebSocketAPI::v3::Wrapper::Accounts::api_token,                1, 'admin'],
    ['tnc_approval',             \&BOM::WebSocketAPI::v3::Wrapper::Accounts::tnc_approval,             1, 'admin'],
    ['login_history',            \&BOM::WebSocketAPI::v3::Wrapper::Accounts::login_history,            1, 'read'],
    ['set_account_currency',     \&BOM::WebSocketAPI::v3::Wrapper::Accounts::set_account_currency,     1, 'admin'],
    ['set_financial_assessment', \&BOM::WebSocketAPI::v3::Wrapper::Accounts::set_financial_assessment, 1, 'admin'],
    ['get_financial_assessment', \&BOM::WebSocketAPI::v3::Wrapper::Accounts::get_financial_assessment, 1, 'admin'],

    ['verify_email', \&BOM::WebSocketAPI::v3::Wrapper::NewAccount::verify_email, 0],
    [
        'new_account_virtual',
        \&BOM::WebSocketAPI::v3::Wrapper::NewAccount::new_account_virtual, 0
    ],
    [
        'reset_password',
        \&BOM::WebSocketAPI::v3::Wrapper::Accounts::reset_password, 0
    ],

    # authenticated calls
    ['sell',        \&BOM::WebSocketAPI::v3::Wrapper::Transaction::sell,        1, 'trade'],
    ['buy',         \&BOM::WebSocketAPI::v3::Wrapper::Transaction::buy,         1, 'trade'],
    ['transaction', \&BOM::WebSocketAPI::v3::Wrapper::Transaction::transaction, 1, 'read'],
    [
        'portfolio',
        \&BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement::portfolio, 1, 'read'
    ],
    [
        'proposal_open_contract',
        \&BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement::proposal_open_contract,
        1, 'read'
    ],
    ['sell_expired', \&BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement::sell_expired, 1, 'trade'],

    ['app_register', \&BOM::WebSocketAPI::v3::Wrapper::App::register,   1, 'admin'],
    ['app_list',     \&BOM::WebSocketAPI::v3::Wrapper::App::list,       1, 'admin'],
    ['app_get',      \&BOM::WebSocketAPI::v3::Wrapper::App::get,        1, 'admin'],
    ['app_delete',   \&BOM::WebSocketAPI::v3::Wrapper::App::delete,     1, 'admin'],
    ['oauth_apps',   \&BOM::WebSocketAPI::v3::Wrapper::App::oauth_apps, 1, 'admin'],

    ['topup_virtual',     \&BOM::WebSocketAPI::v3::Wrapper::Cashier::topup_virtual,     1, 'trade'],
    ['get_limits',        \&BOM::WebSocketAPI::v3::Wrapper::Cashier::get_limits,        1, 'read'],
    ['paymentagent_list', \&BOM::WebSocketAPI::v3::Wrapper::Cashier::paymentagent_list, 0],
    [
        'paymentagent_withdraw',
        \&BOM::WebSocketAPI::v3::Wrapper::Cashier::paymentagent_withdraw, 1, 'payments'
    ],
    [
        'paymentagent_transfer',
        \&BOM::WebSocketAPI::v3::Wrapper::Cashier::paymentagent_transfer, 1, 'payments'
    ],
    [
        'transfer_between_accounts',
        \&BOM::WebSocketAPI::v3::Wrapper::Cashier::transfer_between_accounts, 1, 'payments'
    ],
    [
        'new_account_real',
        \&BOM::WebSocketAPI::v3::Wrapper::NewAccount::new_account_real, 1, 'admin'
    ],
    [
        'new_account_japan',
        \&BOM::WebSocketAPI::v3::Wrapper::NewAccount::new_account_japan, 1, 'admin'
    ],
    [
        'new_account_maltainvest',
        \&BOM::WebSocketAPI::v3::Wrapper::NewAccount::new_account_maltainvest,
        1, 'admin'
    ],
    [
        'jp_knowledge_test',
        \&BOM::WebSocketAPI::v3::Wrapper::NewAccount::jp_knowledge_test, 1, 'admin'
    ],
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
        category      => $category,
        order         => $order,
        handler       => $dispatch->[1],
        require_auth  => $dispatch->[2],
        out_validator => $out_validator,
        in_validator  => $in_validator,
        require_scope => $dispatch->[3],
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

        DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.call.' . $descriptor->{category}, {tags => [$tag]});
        DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.call.all', {tags => [$tag, "category:$descriptor->{category}"]});

        my $loginid = $c->stash('loginid');
        if ($descriptor->{require_auth} and not $loginid) {
            return $c->new_error($descriptor->{category}, 'AuthorizationRequired', $c->l('Please log in.'));
        }

        if ($descriptor->{require_scope} and not(grep { $_ eq $descriptor->{require_scope} } @{$c->stash('token_scopes') || []})) {
            return $c->new_error($descriptor->{category}, 'PermissionDenied',
                $c->l('Permission denied, requiring [_1]', $descriptor->{require_scope}));
        }

        if ($loginid) {
            my $account_type = $c->stash('is_virtual') ? 'virtual' : 'real';
            DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.authenticated_call.all',
                {tags => [$tag, $descriptor->{category}, "loginid:$loginid", "account_type:$account_type"]});
        }

        my $result = $descriptor->{handler}->($c, $p1);

        if ($result) {
            my $output_validation_result = $descriptor->{out_validator}->validate($result);
            if (not $output_validation_result) {
                my $error = join(" - ", $output_validation_result->errors);
                $log->warn("Invalid output parameter for [ " . JSON::to_json($result) . " error: $error ]");
                return $c->new_error($descriptor->{category}, 'OutputValidationFailed', $c->l("Output validation failed: ") . $error);
            }
        }
        $result->{debug} = [Time::HiRes::tv_interval($t0), $loginid ? $loginid : ''] if ref $result;
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
        or $value !~ /^[\p{Script=Common}\p{L}\s\w\@_:!-~]{0,300}$/
        )
    {
        return ($key, $value);
    }
    return;
}

sub rpc {
    my $self        = shift;
    my $method      = shift;
    my $callback    = shift;
    my $params      = shift;
    my $method_name = shift // $method;

    my $tv = [Time::HiRes::gettimeofday];
    state $cpu = Proc::CPUUsage->new();

    $params->{language} = $self->stash('language');
    my $country_code = $self->stash('country') ? $self->stash('country') : $self->stash('request')->country_code;
    $params->{country} = $country_code;

    my $client = MojoX::JSON::RPC::Client->new;
    my $url    = 'http://127.0.0.1:5005/' . $method;
    if (BOM::System::Config::env eq 'production') {
        if (BOM::System::Config::node->{node}->{www2}) {
            $url = 'http://internal-rpc-www2-703689754.us-east-1.elb.amazonaws.com:5005/' . $method;
        } else {
            $url = 'http://internal-rpc-1484966228.us-east-1.elb.amazonaws.com:5005/' . $method;
        }
    }

    my $callobj = {
        id     => Data::UUID->new()->create_str(),
        method => $method,
        params => $params
    };

    $client->call(
        $url, $callobj,
        sub {
            my $res = pop;

            DataDog::DogStatsd::Helper::stats_timing(
                'bom_websocket_api.v_3.rpc.call.timing',
                1000 * Time::HiRes::tv_interval($tv),
                {tags => ["rpc:$method"]});
            DataDog::DogStatsd::Helper::stats_timing('bom_websocket_api.v_3.cpuusage', $cpu->usage(), {tags => ["rpc:$method"]});
            DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.rpc.call.count', {tags => ["rpc:$method"]});

            # unconditionally stop any further processing if client is already disconnected
            return unless $self->tx;

            my $client_guard = guard { undef $client };

            my ($data, $req_id);
            my $args = $params->{args};
            $req_id = $args->{req_id} if ($args and exists $args->{req_id});

            if (!$res) {
                my $tx_res = $client->tx->res;
                warn $tx_res->message;
                $data = $self->new_error($method, 'WrongResponse', $self->l('Sorry, an error occurred while processing your request.'));
                $data->{echo_req} = $args;
                $data->{req_id} = $req_id if $req_id;
                $self->send({json => $data});
                return;
            }

            my $rpc_time;
            $rpc_time = delete $res->result->{rpc_time} if (ref($res->result) eq "HASH");

            if ($rpc_time) {
                DataDog::DogStatsd::Helper::stats_timing(
                    'bom_websocket_api.v_3.rpc.call.timing.connection',
                    1000 * Time::HiRes::tv_interval($tv) - $rpc_time,
                    {tags => ["rpc:$method"]});
            }

            if ($res->is_error) {
                warn $res->error_message;
                $data = $self->new_error($method_name, 'CallError', $self->l('Sorry, an error occurred while processing your request.'));
                $data->{echo_req} = $args;
                $data->{req_id} = $req_id if $req_id;
                $self->send({json => $data});
                return;
            }
            my $send = 1;

            $data = &$callback($res->result);

            if (not $data) {
                $send = undef;
                $data = {};
            }
            my $l = length JSON::to_json($data);
            if ($l > 328000) {
                $data = $self->new_error('error', 'ResponseTooLarge', $self->l('Response too large.'));
            }

            $data->{echo_req} = $args;
            $data->{req_id} = $req_id if $req_id;

            if ($send) {
                $tv = [Time::HiRes::gettimeofday];

                $self->send({json => $data});

                DataDog::DogStatsd::Helper::stats_timing(
                    'bom_websocket_api.v_3.rpc.call.timing.sent',
                    1000 * Time::HiRes::tv_interval($tv),
                    {tags => ["rpc:$method"]});

            }
            return;
        });
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
        $c->app->log->warn("Sanity check failed: $failed[0] -> $failed[1]");
        return $c->new_error('sanity_check', 'SanityCheckFailed', $c->l("Parameters sanity check failed."));
    }
    return;
}

1;
