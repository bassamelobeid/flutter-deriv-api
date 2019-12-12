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
                require_auth           => 'read',
                before_forward         => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::before_forward_balance,
                after_got_rpc_response => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::subscribe_transaction_channel,
                error                  => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::balance_error_handler,
                success                => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::balance_success_handler,
                response               => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::balance_response_handler,
            }
        ],

        ['statement',          {require_auth => 'read'}],
        ['request_report',     {require_auth => 'read'}],
        ['account_statistics', {require_auth => 'read'}],
        ['profit_table',       {require_auth => 'read'}],
        ['get_account_status', {require_auth => 'read'}],
        [
            'change_password',
            {
                require_auth => 'admin',
                stash_params => [qw/ token_type client_ip /],
            }
        ],
        ['get_settings',     {require_auth => 'read'}],
        ['mt5_get_settings', {require_auth => 'read'}],
        [
            'set_settings',
            {
                require_auth => 'admin',
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'mt5_password_check',
            {
                require_auth => 'admin',
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'mt5_password_change',
            {
                require_auth => 'admin',
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'mt5_password_reset',
            {
                require_auth => 'admin',
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        ['get_self_exclusion', {require_auth => 'read'}],
        [
            'set_self_exclusion',
            {
                require_auth => 'admin',
                response     => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::set_self_exclusion_response_handler,
            }
        ],
        [
            'api_token',
            {
                require_auth => 'admin',
                stash_params => [qw/ account_id client_ip /],
            }
        ],
        ['tnc_approval', {require_auth => 'admin'}],
        [
            'login_history',
            {
                require_auth => 'read',
                response     => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::login_history_response_handler,
            }
        ],
        [
            'set_account_currency',
            {
                require_auth   => 'admin',
                before_forward => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::set_account_currency_params_handler,
            }
        ],
        ['set_financial_assessment', {require_auth => 'admin'}],
        ['get_financial_assessment', {require_auth => 'read'}],
        ['reality_check',            {require_auth => 'read'}],
        ['verify_email',             {stash_params => [qw/ server_name token /]}],
        ['new_account_virtual',      {stash_params => [qw/ server_name client_ip user_agent /]}],
        ['reset_password'],

        # authenticated calls
        [
            'contract_update',
            {
                require_auth => 'trade',
                success      => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::contract_update_handler,
            }
        ],
        ['sell', {require_auth => 'trade'}],
        [
            'buy',
            {
                require_auth   => 'trade',
                before_forward => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::buy_get_contract_params,
                success        => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::buy_get_single_contract,
                response       => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::buy_set_poc_subscription_id,
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
        ['sell_contract_for_multiple_accounts', {require_auth => 'trade'}],
        [
            'transaction',
            {
                require_auth   => 'read',
                before_forward => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::transaction,
            }
        ],
        ['portfolio', {require_auth => 'read'}],
        [
            'proposal_open_contract',
            {
                require_auth    => 'read',
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::Pricer::proposal_open_contract,
            }
        ],
        ['sell_expired', {require_auth => 'trade'}],

        ['app_register', {require_auth => 'admin'}],
        ['app_list',     {require_auth => 'read'}],
        ['app_get',      {require_auth => 'read'}],
        ['app_update',   {require_auth => 'admin'}],
        [
            'app_delete',
            {
                require_auth => 'admin',
                success      => \&Binary::WebSocketAPI::v3::Wrapper::App::block_app_id,
            }
        ],
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
                stash_params => [qw/ token_type /],
            }
        ],
        [
            'cashier',
            {
                require_auth => 'payments',
                stash_params => [qw/ server_name domain /],
            }
        ],
        [
            'new_account_real',
            {
                require_auth => 'admin',
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'new_account_maltainvest',
            {
                require_auth => 'admin',
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        ['account_closure', {require_auth => 'admin'}],
        [
            'mt5_login_list',
            {
                require_auth => 'read',
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'mt5_new_account',
            {
                require_auth => 'admin',
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'mt5_deposit',
            {
                require_auth => 'admin',
                response     => Binary::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('mt5_deposit'),
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'mt5_withdrawal',
            {
                require_auth => 'admin',
                response     => Binary::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('mt5_withdrawal'),
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'document_upload',
            {
                stash_params    => [qw/ token /],
                require_auth    => 'admin',
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::DocumentUpload::add_upload_info,
            }
        ],

        ['copytrading_statistics'],
        ['copytrading_list', {require_auth => 'admin'}],
        ['copy_start',       {require_auth => 'trade'}],
        ['copy_stop',        {require_auth => 'trade'}],

        ['app_markup_details', {require_auth => 'read'}],
        ['account_security',   {require_auth => 'admin'}],
        ['notification_event', {require_auth => 'admin'}],
        [
            'service_token',
            {
                require_auth => 'admin',
                stash_params => [qw/ referrer /],
            }
        ],
        ['exchange_rates', {stash_params => [qw/ exchange_rates base_currency /]}],
        # P2P cashier
        [p2p_offer_info    => {require_auth => 'payments'}],
        [p2p_offer_list    => {require_auth => 'payments'}],
        [p2p_order_cancel  => {require_auth => 'payments'}],
        [p2p_order_confirm => {require_auth => 'payments'}],
        [p2p_order_create  => {require_auth => 'payments'}],
        [p2p_order_info    => {require_auth => 'payments'}],
        [p2p_order_list    => {require_auth => 'payments'}],
        [p2p_order_update  => {require_auth => 'payments'}],
        [p2p_agent_info    => {require_auth => 'payments'}],
    ];
}

1;
