# TODO DELETE
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

# [param key, sub, require auth]
my @dispatch = (
    ['authorize', '', 0, ''],
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
    ['proposal',                \&BOM::WebSocketAPI::v3::Wrapper::Streamer::proposal,      0],
    ['price_stream',            \&BOM::WebSocketAPI::v3::Wrapper::Streamer::price_stream,  0],
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
    ['new_account_virtual', '', 0],
    ['reset_password',      '', 0],

    # authenticated calls
    ['sell', '', 1, 'trade'],
    [
        'buy', '', 1, 'trade',
        {
            before_forward => \&BOM::WebSocketAPI::v3::Wrapper::Transaction::buy_get_contract_params,
        }
    ],
    ['transaction', '', 1, 'read', {before_forward => \&BOM::WebSocketAPI::v3::Wrapper::Transaction::transaction}],
    ['portfolio',   '', 1, 'read'],
    [
        'proposal_open_contract',
        '', 1, 'read',
        {
            rpc_response_cb => \&BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement::proposal_open_contract,
        }
    ],
    ['sell_expired', '', 1, 'trade'],

    ['app_register', '', 1, 'admin'],
    ['app_list',     '', 1, 'admin'],
    ['app_get',      '', 1, 'admin'],
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
    ['cashier',                 '', 1, 'payments'],
    ['new_account_real',        '', 1, 'admin'],
    ['new_account_japan',       '', 1, 'admin'],
    ['new_account_maltainvest', '', 1, 'admin'],
    ['jp_knowledge_test',       '', 1, 'admin'],
);

1;
