package BOM::WebSocketAPI;

use Mojo::Base 'Mojolicious';
use Mojo::Redis2;
use Mojo::IOLoop;

use Try::Tiny;
use Data::UUID;
use RateLimitations qw(within_rate_limits);

# pre-load controlleres to have more shared code among workers (COW)
use BOM::WebSocketAPI::CallingEngine();

use BOM::WebSocketAPI::v3::Wrapper::Streamer;
use BOM::WebSocketAPI::v3::Wrapper::Transaction;
use BOM::WebSocketAPI::v3::Wrapper::Authorize;
use BOM::WebSocketAPI::v3::Wrapper::System;
use BOM::WebSocketAPI::v3::Wrapper::Accounts;
use BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery;
use BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement;
use BOM::WebSocketAPI::v3::Wrapper::Cashier;
use BOM::WebSocketAPI::v3::Wrapper::NewAccount;
use BOM::WebSocketAPI::v3::Wrapper::Pricer;

sub apply_usergroup {
    my ($cf, $log) = @_;

    if ($> == 0) {    # we are root
        my $group = $cf->{group};
        if ($group) {
            $group = (getgrnam $group)[2] unless $group =~ /^\d+$/;
            $(     = $group;                                          ## no critic
            $)     = "$group $group";                                 ## no critic
            $log->("Switched group: RGID=$( EGID=$)");
        }

        my $user = $cf->{user} // 'nobody';
        if ($user) {
            $user = (getpwnam $user)[2] unless $user =~ /^\d+$/;
            $<    = $user;                                            ## no critic
            $>    = $user;                                            ## no critic
            $log->("Switched user: RUID=$< EUID=$>");
        }
    }
    return;
}

sub startup {
    my $app = shift;

    Mojo::IOLoop->singleton->reactor->on(
        error => sub {
            my ($reactor, $err) = @_;
            $app->log->error("EventLoop error: $err");
        });

    $app->moniker('websocket');
    $app->plugin('Config' => {file => $ENV{WEBSOCKET_CONFIG} || '/etc/rmg/websocket.conf'});

    my $log = $app->log;

    my $signature = "Binary.com Websockets API";

    $log->info("$signature: Starting.");
    $log->info("Mojolicious Mode is " . $app->mode);
    $log->info("Log Level        is " . $log->level);

    apply_usergroup $app->config->{hypnotoad}, sub {
        $log->info(@_);
    };

    $app->hook(
        before_dispatch => sub {
            my $c = shift;

            if (my $lang = $c->param('l')) {
                $c->stash(language => uc $lang);
                $c->res->headers->header('Content-Language' => lc $lang);
            }

            if ($c->req->param('debug')) {
                $c->stash(debug => 1);
            }

            if ($c->req->param('app_id')) {
                my $app_id = $c->req->param('app_id');

                my $error;
                APP_ID:
                {
                    if ($app_id !~ /^\d+$/) {
                        $error = 1;
                        last;
                    }

                    my $oauth = BOM::Database::Model::OAuth->new;
                    my $app   = $oauth->verify_app($app_id);

                    if (not $app) {
                        $error = 1;
                        last;
                    }

                    $c->stash(
                        source   => $app_id,
                        app_name => $app->{name},
                    );
                }

                if ($error) {
                    $c->send({json => $c->new_error('error', 'InvalidAppID', $c->l('Your app_id is invalid.'))});
                    $c->finish();
                }
            }

            $c->stash(
                server_name  => $c->server_name,
                client_ip    => $c->client_ip,
                country_code => $c->country_code,
                user_agent   => $c->req->headers->header('User-Agent'),
            );
        });

    $app->plugin('ClientIP');
    $app->plugin('BOM::WebSocketAPI::Plugins::Helpers');

    $app->plugin(
        'BOM::WebSocketAPI::Plugins::WebSocketProxy' => {
            actions => [
                ['authorize'],
                [
                    'logout',
                    {
                        stash_params => [qw/ token token_type email client_ip country_code user_agent /],
                        success      => \&BOM::WebSocketAPI::v3::Wrapper::Authorize::logout_success,
                    },
                ],
                ['trading_times'],
                [
                    'asset_index',
                    {
                        before_forward => \&BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery::asset_index_cached,
                        success        => \&BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery::cache_asset_index,
                    }
                ],
                ['active_symbols', {stash_params => [qw/ token /]}],

                ['ticks',         {instead_of_forward => \&BOM::WebSocketAPI::v3::Wrapper::Streamer::ticks}],
                ['ticks_history', {instead_of_forward => \&BOM::WebSocketAPI::v3::Wrapper::Streamer::ticks_history}],
                ['proposal',      {instead_of_forward => \&BOM::WebSocketAPI::v3::Wrapper::Streamer::proposal}],
                ['price_stream',  {instead_of_forward => \&BOM::WebSocketAPI::v3::Wrapper::Pricer::price_stream}],
                ['pricing_table', {instead_of_forward => \&BOM::WebSocketAPI::v3::Wrapper::Streamer::pricing_table}],
                ['forget',        {instead_of_forward => \&BOM::WebSocketAPI::v3::Wrapper::System::forget}],
                ['forget_all',    {instead_of_forward => \&BOM::WebSocketAPI::v3::Wrapper::System::forget_all}],
                ['ping',          {instead_of_forward => \&BOM::WebSocketAPI::v3::Wrapper::System::ping}],
                ['time',          {instead_of_forward => \&BOM::WebSocketAPI::v3::Wrapper::System::server_time}],

                ['website_status', {stash_params => [qw/ country_code /]}],
                ['contracts_for'],
                ['residence_list'],
                ['states_list'],
                ['payout_currencies', {stash_params => [qw/ token /]}],
                ['landing_company'],
                ['landing_company_details'],
                ['get_corporate_actions'],

                [
                    'balance',
                    {
                        require_auth   => 'read',
                        before_forward => \&BOM::WebSocketAPI::v3::Wrapper::Accounts::subscribe_transaction_channel,
                        error          => \&BOM::WebSocketAPI::v3::Wrapper::Accounts::balance_error_handler,
                        success        => \&BOM::WebSocketAPI::v3::Wrapper::Accounts::balance_success_handler,
                    }
                ],

                ['statement',          {require_auth => 'read'}],
                ['profit_table',       {require_auth => 'read'}],
                ['get_account_status', {require_auth => 'read'}],
                [
                    'change_password',
                    {
                        require_auth => 'admin',
                        stash_params => [qw/ token_type client_ip /]}
                ],
                ['get_settings', {require_auth => 'read'}],
                [
                    'set_settings',
                    {
                        require_auth => 'admin',
                        stash_params => [qw/ server_name client_ip user_agent /]}
                ],
                ['get_self_exclusion', {require_auth => 'read'}],
                [
                    'set_self_exclusion',
                    {
                        require_auth => 'admin',
                        response     => \&BOM::WebSocketAPI::v3::Wrapper::Accounts::set_self_exclusion_response_handler
                    }
                ],
                [
                    'cashier_password',
                    {
                        require_auth => 'payments',
                        stash_params => [qw/ client_ip /]}
                ],

                [
                    'api_token',
                    {
                        require_auth => 'admin',
                        stash_params => [qw/ account_id /]}
                ],
                ['tnc_approval', {require_auth => 'admin'}],
                [
                    'login_history',
                    {
                        require_auth => 'read',
                        response     => \&BOM::WebSocketAPI::v3::Wrapper::Accounts::login_history_response_handler
                    }
                ],
                [
                    'set_account_currency',
                    {
                        require_auth     => 'admin',
                        make_call_params => \&BOM::WebSocketAPI::v3::Wrapper::Accounts::set_account_currency_params_handler
                    }
                ],
                ['set_financial_assessment', {require_auth => 'admin'}],
                ['get_financial_assessment', {require_auth => 'admin'}],
                ['reality_check',            {require_auth => 'read'}],

                [
                    'verify_email',
                    {
                        before_call  => [\&BOM::WebSocketAPI::v3::Wrapper::NewAccount::verify_email_get_type_code],
                        stash_params => [qw/ server_name /],
                    }
                ],
                ['new_account_virtual'],
                ['reset_password'],

                # authenticated calls
                ['sell', {require_auth => 'trade'}],
                [
                    'buy',
                    {
                        require_auth   => 'trade',
                        before_forward => \&BOM::WebSocketAPI::v3::Wrapper::Transaction::buy_get_contract_params,
                    }
                ],
                [
                    'transaction',
                    {
                        require_auth   => 'read',
                        before_forward => \&BOM::WebSocketAPI::v3::Wrapper::Transaction::transaction
                    }
                ],
                [
                    'portfolio',
                    {
                        require_auth => 'read',
                    }
                ],
                [
                    'proposal_open_contract',
                    {
                        require_auth    => 'read',
                        rpc_response_cb => \&BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement::proposal_open_contract,
                    }
                ],
                [
                    'sell_expired',
                    {
                        require_auth => 'trade',
                    }
                ],

                ['app_register', {require_auth => 'admin'}],
                ['app_list',     {require_auth => 'admin'}],
                ['app_get',      {require_auth => 'admin'}],
                ['app_delete',   {require_auth => 'admin'}],
                ['oauth_apps',   {require_auth => 'admin'}],

                ['topup_virtual',     {require_auth => 'trade'}],
                ['get_limits',        {require_auth => 'read'}],
                ['paymentagent_list', {stash_params => [qw/ token /]}],
                [
                    'paymentagent_withdraw',
                    {
                        require_auth => 'payments',
                        error        => \&BOM::WebSocketAPI::v3::Wrapper::Cashier::log_paymentagent_error,
                        response     => BOM::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('paymentagent_withdraw'),
                        stash_params => [qw/ server_name /],
                    }
                ],
                [
                    'paymentagent_transfer',
                    {
                        require_auth => 'payments',
                        error        => \&BOM::WebSocketAPI::v3::Wrapper::Cashier::log_paymentagent_error,
                        response     => BOM::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('paymentagent_transfer'),
                        stash_params => [qw/ server_name /],
                    }
                ],
                [
                    'transfer_between_accounts',
                    {
                        require_auth => 'payments',
                        error        => \&BOM::WebSocketAPI::v3::Wrapper::Cashier::log_paymentagent_error,
                        response     => BOM::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('transfer_between_accounts'),
                    }
                ],
                ['cashier',                 {require_auth => 'payments'}],
                ['new_account_real',        {require_auth => 'admin'}],
                ['new_account_japan',       {require_auth => 'admin'}],
                ['new_account_maltainvest', {require_auth => 'admin'}],
                ['jp_knowledge_test',       {require_auth => 'admin'}],
            ],

            # action hooks
            before_forward           => [\&before_forward,     \&start_timing],
            after_forward            => [\&after_forward],
            before_get_rpc_response  => [\&log_call_timing],
            after_got_rpc_response   => [\&log_call_timing_connection],
            before_send_api_response => [\&add_rpc_call_debug, \&start_timing],
            after_sent_api_response  => [\&log_call_timing_sent],
            after_dispatch           => [\&clear_db_cache],

            # main config
            base_path         => '/websockets/v3',
            stream_timeout    => 120,
            max_connections   => 100000,
            opened_connection => \&init_redis_connections,
            finish_connection => \&forget_all,
        });

    return;
}

sub start_timing {
    my ($c, $req_storage) = @_;
    $req_storage->{tv} = [Time::HiRes::gettimeofday];
    return;
}

sub log_call_timing {
    my ($c, $req_storage) = @_;
    DataDog::DogStatsd::Helper::stats_timing(
        'bom_websocket_api.v_3.rpc.call.timing',
        1000 * Time::HiRes::tv_interval($req_storage->{tv}),
        {tags => ["rpc:$req_storage->{method}"]});
    DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.rpc.call.count', {tags => ["rpc:$req_storage->{method}"]});
    return;
}

sub log_call_timing_connection {
    my ($c, $req_storage, $rpc_response) = @_;
    if (ref($rpc_response->result) eq "HASH"
        && (my $rpc_time = delete $rpc_response->result->{rpc_time}))
    {
        DataDog::DogStatsd::Helper::stats_timing(
            'bom_websocket_api.v_3.rpc.call.timing.connection',
            1000 * Time::HiRes::tv_interval($req_storage->{tv}) - $rpc_time,
            {tags => ["rpc:$req_storage->{method}"]});
    }
    return;
}

sub add_rpc_call_debug {
    my ($c, $req_storage, $api_response) = @_;
    if ($c->stash('debug')) {
        $api_response->{debug} = {
            time   => 1000 * Time::HiRes::tv_interval($req_storage->{tv}),
            method => $req_storage->{method},
        };
    }
    return;
}

sub log_call_timing_sent {
    my ($c, $req_storage) = @_;
    DataDog::DogStatsd::Helper::stats_timing(
        'bom_websocket_api.v_3.rpc.call.timing.sent',
        1000 * Time::HiRes::tv_interval($req_storage->{tv}),
        {tags => ["rpc:$req_storage->{method}"]});
    return;
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

sub reached_limit_check {
    my ($c, $req_storage) = @_;

    # For authorized calls that are heavier we will limit based on loginid
    # For unauthorized calls that are less heavy we will use connection id.
    # None are much helpful in a well prepared DDoS.
    my $consumer         = $c->stash('loginid') || $c->stash('connection_id');
    my $category         = $req_storage->{name};
    my $is_real          = $c->stash('loginid') && !$c->stash('is_virtual');
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
                consumer => $consumer,
            }))
    {
        return $c->new_error($category, 'RateLimit', $c->l('You have reached the rate limit for [_1].', $category));
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

sub before_forward {
    my ($c, $req_storage) = @_;

    my $args = $req_storage->{args};
    if (not $c->stash('connection_id')) {
        $c->stash('connection_id' => Data::UUID->new()->create_str());
    }

    $req_storage->{handle_t0} = [Time::HiRes::gettimeofday];

    if (my $reached = reached_limit_check($c, $req_storage)) {
        return $reached;
    }

    my $input_validation_result = $req_storage->{in_validator}->validate($args);
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
        return $c->new_error($req_storage->{name}, 'InputValidationFailed', $message, $details);
    }

    _set_defaults($req_storage, $args);

    my $tag = 'origin:';
    if (my $origin = $c->req->headers->header("Origin")) {
        if ($origin =~ /https?:\/\/([a-zA-Z0-9\.]+)$/) {
            $tag = "origin:$1";
        }
    }

    DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.call.' . $req_storage->{name}, {tags => [$tag]});
    DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.call.all', {tags => [$tag, "category:$req_storage->{name}"]});

    my $loginid = $c->stash('loginid');
    if ($req_storage->{require_auth} and not $loginid) {
        return $c->new_error($req_storage->{name}, 'AuthorizationRequired', $c->l('Please log in.'));
    }

    if ($req_storage->{require_auth} and not(grep { $_ eq $req_storage->{require_auth} } @{$c->stash('scopes') || []})) {
        return $c->new_error($req_storage->{name}, 'PermissionDenied', $c->l('Permission denied, requiring [_1]', $req_storage->{require_auth}));
    }

    if ($loginid) {
        my $account_type = $c->stash('is_virtual') ? 'virtual' : 'real';
        DataDog::DogStatsd::Helper::stats_inc('bom_websocket_api.v_3.authenticated_call.all',
            {tags => [$tag, $req_storage->{name}, "account_type:$account_type"]});
    }

    return;
}

sub after_forward {
    my ($c, $args, $result, $req_storage) = @_;

    return unless $result;

    if ($result) {
        my $output_validation_result = $req_storage->{out_validator}->validate($result);
        if (not $output_validation_result) {
            my $error = join(" - ", $output_validation_result->errors);
            $c->app->log->warn("Invalid output parameter for [ " . JSON::to_json($result) . " error: $error ]");
            $result = $c->new_error($req_storage->{category}, 'OutputValidationFailed', $c->l("Output validation failed: ") . $error);
        }
    }
    if (ref($result) && $c->stash('debug')) {
        $result->{debug} = {
            time   => 1000 * Time::HiRes::tv_interval($req_storage->{hadle_t0}),
            method => $req_storage->{method},
        };
    }
    my $l = length JSON::to_json($result || {});
    if ($l > 328000) {
        $result = $c->new_error('error', 'ResponseTooLarge', $c->l('Response too large.'));
        $result->{echo_req} = $args;
    }

    $result->{req_id} = $args->{req_id} if exists $args->{req_id};
    return $result;
}

sub init_redis_connections {
    my $c = shift;
    $c->redis;
    $c->redis_pricer;
    return;
}

sub forget_all {
    my $c = shift;
    # stop all recurring
    BOM::WebSocketAPI::v3::Wrapper::System::forget_all($c, {forget_all => 1});
    delete $c->stash->{redis};
    delete $c->stash->{redis_pricer};
    return;
}

sub clear_db_cache {
    BOM::Database::Rose::DB->db_cache->finish_request_cycle;
    return;
}

1;
