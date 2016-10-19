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
use BOM::WebSocketAPI::v3::Wrapper::Cashier;
use BOM::WebSocketAPI::v3::Wrapper::Pricer;

use File::Slurp;
use JSON::Schema;
use Try::Tiny;
use Format::Util::Strings qw( defang_lite );
use Digest::MD5 qw(md5_hex);

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

            my $lang = defang_lite($c->param('l'));
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

            my $app_id    = defang_lite($c->req->param('app_id'));
            my $client_ip = $c->client_ip;

            if ($c->tx and $c->tx->req and $c->tx->req->headers->header('REMOTE_ADDR')) {
                $client_ip = $c->tx->req->headers->header('REMOTE_ADDR');
            }

            my $user_agent = $c->req->headers->header('User-Agent');
            $c->stash(
                server_name    => $c->server_name,
                client_ip      => $client_ip,
                country_code   => $c->country_code,
                user_agent     => $user_agent,
                ua_fingerprint => md5_hex(($app_id // 0) . ($client_ip // '') . ($user_agent // '')),
                $app_id ? (source => $app_id) : (),
            );
        });

    $app->plugin('ClientIP');
    $app->plugin('BOM::WebSocketAPI::Plugins::Helpers');

    my $actions = [
        ['authorize', {stash_params => [qw/ ua_fingerprint client_ip user_agent /]}],
        [
            'logout',
            {
                stash_params => [qw/ token token_type email client_ip user_agent /],
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
        ['proposal',      {instead_of_forward => \&BOM::WebSocketAPI::v3::Wrapper::Pricer::proposal}],
        ['forget',        {instead_of_forward => \&BOM::WebSocketAPI::v3::Wrapper::System::forget}],
        ['forget_all',    {instead_of_forward => \&BOM::WebSocketAPI::v3::Wrapper::System::forget_all}],
        ['ping',          {instead_of_forward => \&BOM::WebSocketAPI::v3::Wrapper::System::ping}],
        ['time',          {instead_of_forward => \&BOM::WebSocketAPI::v3::Wrapper::System::server_time}],

        ['website_status'],
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
        ['get_settings',     {require_auth => 'read'}],
        ['mt5_get_settings', {require_auth => 'read'}],
        [
            'set_settings',
            {
                require_auth => 'admin',
                stash_params => [qw/ server_name client_ip user_agent /]}
        ],
        [
            'mt5_set_settings',
            {
                require_auth => 'admin',
                stash_params => [qw/ server_name client_ip user_agent /]}
        ],
        [
            'mt5_password_check',
            {
                require_auth => 'admin',
                stash_params => [qw/ server_name client_ip user_agent /]}
        ],
        [
            'mt5_password_change',
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
                require_auth   => 'admin',
                before_forward => \&BOM::WebSocketAPI::v3::Wrapper::Accounts::set_account_currency_params_handler
            }
        ],
        ['set_financial_assessment', {require_auth => 'admin'}],
        ['get_financial_assessment', {require_auth => 'admin'}],
        ['reality_check',            {require_auth => 'read'}],
        ['verify_email',             {stash_params => [qw/ server_name token /]}],
        ['new_account_virtual',      {stash_params => [qw/ server_name client_ip user_agent /]}],
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
            'buy_contract_for_multiple_accounts',
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
                rpc_response_cb => \&BOM::WebSocketAPI::v3::Wrapper::Pricer::proposal_open_contract,
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

        ['connect_add',  {require_auth => 'admin'}],
        ['connect_del',  {require_auth => 'admin'}],
        ['connect_list', {require_auth => 'admin'}],

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
        [
            'cashier',
            {
                require_auth => 'payments',
                stash_params => [qw/ server_name /],
            }
        ],
        [
            'new_account_real',
            {
                require_auth => 'admin',
                stash_params => [qw/ server_name client_ip user_agent /]}
        ],
        [
            'new_account_japan',
            {
                require_auth => 'admin',
                stash_params => [qw/ server_name client_ip user_agent /]}
        ],
        [
            'new_account_maltainvest',
            {
                require_auth => 'admin',
                stash_params => [qw/ server_name client_ip user_agent /]}
        ],
        [
            'new_sub_account',
            {
                require_auth => 'admin',
                stash_params => [qw/ server_name client_ip user_agent /]}
        ],
        [
            'mt5_login_list',
            {
                require_auth => 'admin',
                stash_params => [qw/ server_name client_ip user_agent /]}
        ],
        [
            'mt5_new_account',
            {
                require_auth => 'admin',
                stash_params => [qw/ server_name client_ip user_agent /]}
        ],
        [
            'mt5_deposit',
            {
                require_auth => 'admin',
                response     => BOM::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('mt5_deposit'),
                stash_params => [qw/ server_name client_ip user_agent /]}
        ],
        [
            'mt5_withdrawal',
            {
                require_auth => 'admin',
                response     => BOM::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('mt5_withdrawal'),
                stash_params => [qw/ server_name client_ip user_agent /]}
        ],
        [
            'jp_knowledge_test',
            {
                require_auth => 'admin',
                stash_params => [qw/ server_name client_ip user_agent /]}
        ],
    ];

    for my $action (@$actions) {
        my $f             = '/home/git/regentmarkets/bom-websocket-api/config/v3/' . $action->[0];
        my $in_validator  = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/send.json")), format => \%JSON::Schema::FORMATS);
        my $out_validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/receive.json")), format => \%JSON::Schema::FORMATS);

        my $action_options = $action->[1] ||= {};
        $action_options->{in_validator}  = $in_validator;
        $action_options->{out_validator} = $out_validator;

        $action_options->{stash_params} ||= [];
        push @{$action_options->{stash_params}}, qw( language country_code );

        push @{$action_options->{stash_params}}, 'token' if $action_options->{require_auth};
    }

    $app->plugin(
        'web_socket_proxy' => {
            actions => $actions,

            # action hooks
            before_forward           => [\&BOM::WebSocketAPI::Hooks::before_forward,             \&BOM::WebSocketAPI::Hooks::get_rpc_url],
            before_call              => [\&BOM::WebSocketAPI::Hooks::add_app_id,                 \&BOM::WebSocketAPI::Hooks::start_timing],
            before_get_rpc_response  => [\&BOM::WebSocketAPI::Hooks::log_call_timing],
            after_got_rpc_response   => [\&BOM::WebSocketAPI::Hooks::log_call_timing_connection, \&BOM::WebSocketAPI::Hooks::error_check],
            before_send_api_response => [
                \&BOM::WebSocketAPI::Hooks::add_req_data,      \&BOM::WebSocketAPI::Hooks::start_timing,
                \&BOM::WebSocketAPI::Hooks::output_validation, \&BOM::WebSocketAPI::Hooks::add_call_debug
            ],
            after_sent_api_response => [\&BOM::WebSocketAPI::Hooks::log_call_timing_sent, \&BOM::WebSocketAPI::Hooks::close_bad_connection],

            # main config
            base_path         => '/websockets/v3',
            stream_timeout    => 120,
            max_connections   => 100000,
            max_response_size => 600000,                                               # change and test this if we ever increase ticks history count
            opened_connection => \&BOM::WebSocketAPI::Hooks::init_redis_connections,
            finish_connection => \&BOM::WebSocketAPI::Hooks::forget_all,

            # helper config
            url => \&BOM::WebSocketAPI::Hooks::get_rpc_url,                            # make url for manually called actions

            # Skip check sanity to password fields
            skip_check_sanity => qr/password/,
        });

    return;
}

1;
