package Binary::WebSocketAPI;

use strict;
use warnings;

no indirect;

use Mojo::Base 'Mojolicious';
use Mojo::Redis2;
use Mojo::IOLoop;

use Binary::WebSocketAPI::Hooks;
use Binary::WebSocketAPI::Plugins::Introspection;
use Binary::WebSocketAPI::v3::Wrapper::Streamer;
use Binary::WebSocketAPI::v3::Wrapper::Transaction;
use Binary::WebSocketAPI::v3::Wrapper::Authorize;
use Binary::WebSocketAPI::v3::Wrapper::System;
use Binary::WebSocketAPI::v3::Wrapper::Accounts;
use Binary::WebSocketAPI::v3::Wrapper::MarketDiscovery;
use Binary::WebSocketAPI::v3::Wrapper::Cashier;
use Binary::WebSocketAPI::v3::Wrapper::Pricer;
use Binary::WebSocketAPI::v3::Wrapper::DocumentUpload;
use Binary::WebSocketAPI::v3::Instance::Redis qw| check_connections |;

use File::Slurp;
use JSON::Schema;
use JSON::XS;
use Format::Util::Strings qw( defang );
use Digest::MD5 qw(md5_hex);
use RateLimitations::Pluggable;
use Time::Duration::Concise;
use Scalar::Util qw(weaken);
use YAML::XS qw(LoadFile);

# FIXME This needs to come from config, requires chef changes
use constant INTROSPECTION_PORT => 8801;

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

    check_connections();                                              ### Raise and check redis connections

    Mojo::IOLoop->singleton->reactor->on(
        error => sub {
            my (undef, $err) = @_;
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

    # binary.com plugins
    push @{$app->plugins->namespaces}, 'Binary::WebSocketAPI::Plugins';
    $app->plugin('Introspection' => {port => 0});
    $app->plugin('RateLimits');

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

            my $client_ip = $c->client_ip;
            my $brand     = defang($c->req->param('brand'));

            if ($c->tx and $c->tx->req and $c->tx->req->headers->header('REMOTE_ADDR')) {
                $client_ip = $c->tx->req->headers->header('REMOTE_ADDR');
            }

            my $user_agent = $c->req->headers->header('User-Agent');
            $c->stash(
                server_name          => $c->server_name,
                client_ip            => $client_ip,
                country_code         => $c->country_code,
                landing_company_name => $c->landing_company_name,
                user_agent           => $user_agent,
                ua_fingerprint       => md5_hex(($app_id // 0) . ($client_ip // '') . ($user_agent // '')),
                ($app_id) ? (source => $app_id) : (),
                brand => (($brand =~ /^\w{1,10}$/) ? $brand : 'binary'),
            );
        });

    $app->plugin('ClientIP');
    $app->plugin('Binary::WebSocketAPI::Plugins::Helpers');

    my $actions = [[
            'authorize',
            {
                stash_params => [qw/ ua_fingerprint client_ip user_agent /],
                success      => \&Binary::WebSocketAPI::v3::Wrapper::Authorize::login_success,
            }
        ],
        [
            'logout',
            {
                stash_params => [qw/ token token_type email client_ip user_agent /],
                success      => \&Binary::WebSocketAPI::v3::Wrapper::Authorize::logout_success,
            },
        ],
        [
            'trading_times',
            {
                instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::MarketDiscovery::trading_times,
            },
        ],
        [
            'asset_index',
            {
                instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::MarketDiscovery::asset_index,
                before_forward     => \&Binary::WebSocketAPI::v3::Wrapper::MarketDiscovery::asset_index_cached,
                success            => \&Binary::WebSocketAPI::v3::Wrapper::MarketDiscovery::cache_asset_index,
            }
        ],
        ['active_symbols', {stash_params => [qw/ token /]}],

        ['ticks',          {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Streamer::ticks}],
        ['ticks_history',  {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Streamer::ticks_history}],
        ['proposal',       {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Pricer::proposal}],
        ['proposal_array', {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Pricer::proposal_array}],
        ['forget',         {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::System::forget}],
        ['forget_all',     {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::System::forget_all}],
        ['ping',           {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::System::ping}],
        ['time',           {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::System::server_time}],
        ['website_status', {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Streamer::website_status}],
        [
            'contracts_for',
            {
                instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::MarketDiscovery::contracts_for,
                stash_params       => [qw/ token /],
            }
        ],
        ['residence_list'],
        ['states_list'],
        ['payout_currencies', {stash_params => [qw/ token landing_company_name /]}],
        ['landing_company'],
        ['landing_company_details'],
        [
            'balance',
            {
                require_auth   => 'read',
                before_forward => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::subscribe_transaction_channel,
                error          => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::balance_error_handler,
                success        => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::balance_success_handler,
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
                response     => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::set_self_exclusion_response_handler
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
                stash_params => [qw/ account_id client_ip /]}
        ],
        ['tnc_approval', {require_auth => 'admin'}],
        [
            'login_history',
            {
                require_auth => 'read',
                response     => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::login_history_response_handler
            }
        ],
        [
            'set_account_currency',
            {
                require_auth   => 'admin',
                before_forward => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::set_account_currency_params_handler
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
                before_forward => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::buy_get_contract_params,
                success        => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::buy_store_last_contract_id,
            }
        ],
        [
            'buy_contract_for_multiple_accounts',
            {
                require_auth   => 'trade',
                before_forward => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::buy_get_contract_params,
                success        => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::buy_store_last_contract_id,
            }
        ],
        [
            'sell_contract_for_multiple_accounts',
            {
                require_auth => 'trade',
            }
        ],
        [
            'transaction',
            {
                require_auth   => 'read',
                before_forward => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::transaction
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
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::Pricer::proposal_open_contract,
            }
        ],
        [
            'sell_expired',
            {
                require_auth => 'trade',
            }
        ],

        ['app_register',     {require_auth => 'admin'}],
        ['app_list',         {require_auth => 'admin'}],
        ['app_get',          {require_auth => 'admin'}],
        ['app_update',       {require_auth => 'admin'}],
        ['app_delete',       {require_auth => 'admin'}],
        ['oauth_apps',       {require_auth => 'read'}],
        ['revoke_oauth_app', {require_auth => 'admin'}],

        ['topup_virtual',     {require_auth => 'trade'}],
        ['get_limits',        {require_auth => 'read'}],
        ['paymentagent_list', {stash_params => [qw/ token /]}],
        [
            'paymentagent_withdraw',
            {
                require_auth => 'payments',
                error        => \&Binary::WebSocketAPI::v3::Wrapper::Cashier::log_paymentagent_error,
                response     => Binary::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('paymentagent_withdraw'),
                stash_params => [qw/ server_name /],
            }
        ],
        [
            'paymentagent_transfer',
            {
                require_auth => 'payments',
                error        => \&Binary::WebSocketAPI::v3::Wrapper::Cashier::log_paymentagent_error,
                response     => Binary::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('paymentagent_transfer'),
                stash_params => [qw/ server_name /],
            }
        ],
        [
            'transfer_between_accounts',
            {
                require_auth => 'payments',
                error        => \&Binary::WebSocketAPI::v3::Wrapper::Cashier::log_paymentagent_error,
                response     => Binary::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('transfer_between_accounts'),
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
                response     => Binary::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('mt5_deposit'),
                stash_params => [qw/ server_name client_ip user_agent /]}
        ],
        [
            'mt5_withdrawal',
            {
                require_auth => 'admin',
                response     => Binary::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('mt5_withdrawal'),
                stash_params => [qw/ server_name client_ip user_agent /]}
        ],
        [
            'jp_knowledge_test',
            {
                require_auth => 'admin',
                stash_params => [qw/ server_name client_ip user_agent /]}
        ],

        ['copytrading_statistics'],
        [
            'document_upload',
            {
                stash_params    => [qw/ token /],
                require_auth    => 'admin',
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::DocumentUpload::add_upload_info,
            }
        ],
        ['copy_start',         {require_auth => 'trade'}],
        ['copy_stop',          {require_auth => 'trade'}],
        ['app_markup_details', {require_auth => 'admin'}]];

    for my $action (@$actions) {
        my $f             = '/home/git/regentmarkets/binary-websocket-api/config/v3/' . $action->[0];
        my $in_validator  = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/send.json")), format => \%JSON::Schema::FORMATS);
        my $out_validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$f/receive.json")), format => \%JSON::Schema::FORMATS);

        my $action_options = $action->[1] ||= {};
        $action_options->{in_validator}  = $in_validator;
        $action_options->{out_validator} = $out_validator;

        $action_options->{stash_params} ||= [];
        push @{$action_options->{stash_params}}, qw( language country_code );

        push @{$action_options->{stash_params}}, 'token' if $action_options->{require_auth};
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
            return "rate_limitations_key: connection closed" unless $c->tx;
            my $login_id           = $c->stash('loginid');
            my $app_id             = $c->app_id // '';
            my $authorised_key     = $login_id ? "rate_limits::authorised::$app_id/$login_id" : undef;
            my $non_authorised_key = do {
                my $ip = $c->client_ip;
                if (!defined $ip) {
                    $app->log->warn("cannot determine client IP-address");
                    $ip = 'unknown-IP';
                }
                my $user_agent = $c->req->headers->header('User-Agent') // 'Unknown-UA';
                my $client_id = md5_hex($ip . ":" . $user_agent);
                "rate_limits::non-authorised::$app_id/$client_id";
            };
            return $authorised_key // $non_authorised_key;
        });

    $app->plugin(
        'web_socket_proxy' => {
            actions      => $actions,
            binary_frame => \&Binary::WebSocketAPI::v3::Wrapper::DocumentUpload::document_upload,
            # action hooks
            before_forward => [
                \&Binary::WebSocketAPI::Hooks::check_app_id, \&Binary::WebSocketAPI::Hooks::before_forward,
                \&Binary::WebSocketAPI::Hooks::get_rpc_url,  \&Binary::WebSocketAPI::Hooks::introspection_before_forward
            ],
            before_call => [
                \&Binary::WebSocketAPI::Hooks::add_app_id,   \&Binary::WebSocketAPI::Hooks::add_brand,
                \&Binary::WebSocketAPI::Hooks::start_timing, \&Binary::WebSocketAPI::Hooks::cleanup_stored_contract_ids
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
            url => \&Binary::WebSocketAPI::Hooks::get_rpc_url,                          # make url for manually called actions

            # Skip check sanity to password fields
            skip_check_sanity => qr/password/,
        });

    return;
}

1;
