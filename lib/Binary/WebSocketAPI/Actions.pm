package Binary::WebSocketAPI::Actions;

use strict;
use warnings;

use Binary::WebSocketAPI::v3::Wrapper::Streamer;
use Binary::WebSocketAPI::v3::Wrapper::Transaction;
use Binary::WebSocketAPI::v3::Wrapper::Authorize;
use Binary::WebSocketAPI::v3::Wrapper::System;
use Binary::WebSocketAPI::v3::Wrapper::Accounts;
use Binary::WebSocketAPI::v3::Wrapper::Cashier;
use Binary::WebSocketAPI::v3::Wrapper::Pricer;
use Binary::WebSocketAPI::v3::Wrapper::DocumentUpload;
use Binary::WebSocketAPI::v3::Wrapper::App;

sub actions_config {
    return [[
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
        ['trading_times'],
        ['trading_durations', {stash_params => [qw/ token /]}],
        ['asset_index',       {stash_params => [qw/ token /]}],
        ['contracts_for',     {stash_params => [qw/ token /]}],
        ['active_symbols',    {stash_params => [qw/ token /]}],

        ['ticks',          {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Streamer::ticks}],
        ['ticks_history',  {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Streamer::ticks_history}],
        ['proposal',       {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Pricer::proposal}],
        ['proposal_array', {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Pricer::proposal_array_deprecated}],
        ['forget',         {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::System::forget}],
        ['forget_all',     {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::System::forget_all}],
        ['ping',           {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::System::ping}],
        ['time',           {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::System::server_time}],
        ['website_status', {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Streamer::website_status}],
        ['residence_list'],
        ['states_list'],
        ['payout_currencies', {stash_params => [qw/ token landing_company_name /]}],
        ['landing_company'],
        ['landing_company_details'],
        [
            'balance',
            {
                before_forward         => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::before_forward_balance,
                after_got_rpc_response => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::subscribe_transaction_channel,
                error                  => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::balance_error_handler,
                success                => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::balance_success_handler,
                response               => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::balance_response_handler,
            }
        ],

        ['statement'],
        ['request_report'],
        ['account_statistics'],
        ['profit_table'],
        ['get_account_status'],
        [
            'change_password',
            {
                stash_params => [qw/ token_type client_ip /],
            }
        ],
        ['get_settings'],
        ['mt5_get_settings'],
        [
            'set_settings',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'mt5_password_check',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'mt5_password_change',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'mt5_password_reset',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        ['get_self_exclusion'],
        [
            'set_self_exclusion',
            {
                response => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::set_self_exclusion_response_handler,
            }
        ],
        [
            'api_token',
            {
                stash_params => [qw/ account_id client_ip /],
            }
        ],
        ['tnc_approval'],
        [
            'login_history',
            {
                response => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::login_history_response_handler,
            }
        ],
        [
            'set_account_currency',
            {
                before_forward => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::set_account_currency_params_handler,
            }
        ],
        ['set_financial_assessment'],
        ['get_financial_assessment'],
        ['reality_check'],
        ['verify_email',        {stash_params => [qw/ server_name token /]}],
        ['new_account_virtual', {stash_params => [qw/ server_name client_ip user_agent /]}],
        ['reset_password'],

        # authenticated calls
        [
            'contract_update',
            {
                success => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::contract_update_handler,
            }
        ],
        ['sell'],
        ['cancel'],
        [
            'buy',
            {
                before_forward => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::buy_get_contract_params,
                success        => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::buy_get_single_contract,
                response       => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::buy_set_poc_subscription_id,
            }
        ],
        [
            'buy_contract_for_multiple_accounts',
            {
                before_forward => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::buy_get_contract_params,
                success        => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::buy_store_last_contract_id,
            }
        ],
        ['sell_contract_for_multiple_accounts'],
        [
            'transaction',
            {
                before_forward => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::transaction,
            }
        ],
        ['portfolio'],
        [
            'proposal_open_contract',
            {
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::Pricer::proposal_open_contract,
            }
        ],
        ['sell_expired'],

        ['app_register'],
        ['app_list'],
        ['app_get'],
        ['app_update'],
        [
            'app_delete',
            {
                success => \&Binary::WebSocketAPI::v3::Wrapper::App::block_app_id,
            }
        ],
        ['oauth_apps'],
        ['revoke_oauth_app'],

        ['topup_virtual'],
        ['get_limits'],
        ['paymentagent_list', {stash_params => [qw/ token /]}],
        [
            'paymentagent_withdraw',
            {
                error        => \&Binary::WebSocketAPI::v3::Wrapper::Cashier::log_paymentagent_error,
                response     => Binary::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('paymentagent_withdraw'),
                stash_params => [qw/ server_name /],
            }
        ],
        [
            'paymentagent_transfer',
            {
                error        => \&Binary::WebSocketAPI::v3::Wrapper::Cashier::log_paymentagent_error,
                response     => Binary::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('paymentagent_transfer'),
                stash_params => [qw/ server_name /],
            }
        ],
        [
            'transfer_between_accounts',
            {
                error        => \&Binary::WebSocketAPI::v3::Wrapper::Cashier::log_paymentagent_error,
                response     => Binary::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('transfer_between_accounts'),
                stash_params => [qw/ token_type /],
            }
        ],
        [
            'cashier',
            {
                stash_params => [qw/ server_name domain /],
            }
        ],
        [
            'new_account_real',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'new_account_maltainvest',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        ['account_closure'],
        [
            'mt5_login_list',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'mt5_new_account',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'mt5_deposit',
            {
                response     => Binary::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('mt5_deposit'),
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'mt5_withdrawal',
            {
                response     => Binary::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('mt5_withdrawal'),
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'document_upload',
            {
                stash_params    => [qw/ token /],
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::DocumentUpload::add_upload_info,
            }
        ],

        ['copytrading_statistics'],
        ['copytrading_list'],
        ['copy_start'],
        ['copy_stop'],

        ['app_markup_details'],
        ['account_security'],
        ['notification_event'],
        [
            'service_token',
            {
                stash_params => [qw/ referrer /],
            }
        ],
        ['exchange_rates', {stash_params => [qw/ exchange_rates base_currency /]}],
        # P2P cashier
        ['p2p_offer_create'],
        ['p2p_offer_info'],
        ['p2p_offer_list'],
        ['p2p_order_cancel'],
        ['p2p_order_confirm'],
        ['p2p_order_create'],
        ['p2p_order_info'],
        ['p2p_order_list'],
        ['p2p_agent_info'],
    ];
}

1;
