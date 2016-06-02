package BOM::WebSocketAPI;

use Mojo::Base 'Mojolicious';
use Mojo::Redis2;
use Mojo::IOLoop;

use BOM::WebSocketAPI::Hooks;
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
            my $client_ip = $c->client_ip;

            if ($c->tx and $c->tx->req and $c->tx->req->headers->header('REMOTE_ADDR')) {
                $client_ip = $c->tx->req->headers->header('REMOTE_ADDR');
            }

            $c->stash(
                server_name  => $c->server_name,
                client_ip    => $client_ip,
                country_code => $c->country_code,
                country      => $c->country_code,
                user_agent   => $c->req->headers->header('User-Agent'),
            );
        });

    $app->plugin('ClientIP');
    $app->plugin('BOM::WebSocketAPI::Plugins::Helpers');

    my $actions = [
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
        ['app_update',   {require_auth => 'admin'}],
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
    ];

    for my $action (@$actions) {
        my $f             = '/home/git/regentmarkets/bom-websocket-api/config/v3/' . $action->[0];
        my $in_validator  = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/send.json")), format => \%JSON::Schema::FORMATS);
        my $out_validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/receive.json")), format => \%JSON::Schema::FORMATS);

        my $action_options = $action->[1] ||= {};
        $action_options->{in_validator}  = $in_validator;
        $action_options->{out_validator} = $out_validator;

        $action_options->{stash_params} ||= [];
        push @{$action_options->{stash_params}}, qw( language country source );

        push @{$action_options->{stash_params}}, 'token' if $action_options->{require_auth};
    }

    $app->plugin(
        'web_socket_proxy' => {
            actions => $actions,

            # action hooks
            before_forward =>
                [\&BOM::WebSocketAPI::Hooks::before_forward, \&BOM::WebSocketAPI::Hooks::get_rpc_url, \&BOM::WebSocketAPI::Hooks::start_timing],
            after_forward           => [\&BOM::WebSocketAPI::Hooks::after_forward],
            before_get_rpc_response => [\&BOM::WebSocketAPI::Hooks::log_call_timing],
            after_got_rpc_response  => [\&BOM::WebSocketAPI::Hooks::log_call_timing_connection],
            before_send_api_response =>
                [\&BOM::WebSocketAPI::Hooks::add_call_debug, \&BOM::WebSocketAPI::Hooks::add_req_data, \&BOM::WebSocketAPI::Hooks::start_timing],
            after_sent_api_response => [\&BOM::WebSocketAPI::Hooks::log_call_timing_sent],
            after_dispatch          => [\&BOM::WebSocketAPI::Hooks::clear_db_cache],

            # main config
            base_path         => '/websockets/v3',
            stream_timeout    => 120,
            max_connections   => 100000,
            opened_connection => \&BOM::WebSocketAPI::Hooks::init_redis_connections,
            finish_connection => \&BOM::WebSocketAPI::Hooks::forget_all,

            # helper config
            url => \&BOM::WebSocketAPI::Hooks::get_rpc_url,    # make url for manually called actions
        });

    return;
}

1;
