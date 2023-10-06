package Binary::WebSocketAPI::Actions;

use strict;
use warnings;

use Binary::WebSocketAPI::v3::Wrapper::Accounts;
use Binary::WebSocketAPI::v3::Wrapper::App;
use Binary::WebSocketAPI::v3::Wrapper::Authorize;
use Binary::WebSocketAPI::v3::Wrapper::Cashier;
use Binary::WebSocketAPI::v3::Wrapper::CashierPayments;
use Binary::WebSocketAPI::v3::Wrapper::DocumentUpload;
use Binary::WebSocketAPI::v3::Wrapper::P2P;
use Binary::WebSocketAPI::v3::Wrapper::Pricer;
use Binary::WebSocketAPI::v3::Wrapper::Streamer;
use Binary::WebSocketAPI::v3::Wrapper::System;
use Binary::WebSocketAPI::v3::Wrapper::Transaction;

sub actions_config {
    return [[
            'authorize',
            {
                stash_params => [qw/ ua_fingerprint client_ip user_agent /],
                success      => \&Binary::WebSocketAPI::v3::Wrapper::Authorize::login_success,
                category     => 'account',
            }
        ],
        [
            'logout',
            {
                stash_params => [qw/ token token_type email client_ip user_agent /],
                success      => \&Binary::WebSocketAPI::v3::Wrapper::Authorize::logout_success,
                category     => 'account',
            },
        ],
        ['trading_times'],
        ['economic_calendar'],
        ['trading_durations', {stash_params => [qw/ token /]}],
        ['asset_index',       {stash_params => [qw/ token /]}],
        ['contracts_for',     {stash_params => [qw/ token /]}],
        ['active_symbols',    {stash_params => [qw/ token /]}],

        ['exchange_rates', {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Streamer::exchange_rates}],
        [
            'ticks',
            {
                instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Streamer::ticks,
                category           => 'tick',
            }
        ],
        [
            'ticks_history',
            {
                instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Streamer::ticks_history,
                category           => 'tick',
            }
        ],
        [
            'proposal',
            {
                instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Pricer::proposal,
                category           => 'pricing'
            }
        ],
        ['forget',         {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::System::forget}],
        ['forget_all',     {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::System::forget_all}],
        ['ping',           {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::System::ping}],
        ['time',           {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::System::server_time}],
        ['website_status', {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Streamer::website_status}],
        ['crypto_config',  {stash_params       => [qw/ token /]}],
        ['residence_list'],
        ['states_list'],
        ['payout_currencies', {stash_params => [qw/ token landing_company_name /]}],
        ['landing_company'],
        ['landing_company_details'],
        [
            'balance',
            {
                stash_params => [qw/ token_type /],
                success      => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::balance_success_handler,
                response     => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::balance_response_handler,
                category     => 'mt5_hybrid',
            }
        ],

        [
            'statement',
            {
                category => 'mt5_hybrid',
            }
        ],

        ['request_report'],
        [
            'account_statistics',
            {
                category => 'account',
            }
        ],
        ['identity_verification_document_add'],
        ['profit_table'],

        [
            'get_account_status',
            {
                category => 'mt5_hybrid',
            }
        ],
        [
            'kyc_auth_status',
            {
                category => 'mt5_hybrid',
            }
        ],

        [
            'change_password',
            {
                stash_params => [qw/ token_type client_ip /],
                category     => 'account',
            }
        ],
        [
            'get_settings',
            {
                category => 'account',
            }
        ],
        [
            'mt5_get_settings',
            {
                category => 'mt5',
            }
        ],
        [
            'set_settings',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
                category     => 'account',
            }
        ],
        [
            'mt5_password_check',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
                category     => 'mt5',
            }
        ],
        [
            'mt5_password_change',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
                category     => 'mt5',
            }
        ],
        [
            'mt5_password_reset',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
                category     => 'mt5',
            }
        ],
        [
            'get_self_exclusion',
            {
                category => 'account',
            }
        ],

        [
            'set_self_exclusion',
            {
                response => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::set_self_exclusion_response_handler,
                category => 'mt5_hybrid',
            }
        ],

        [
            'api_token',
            {
                stash_params => [qw/ account_id client_ip /],
                category     => 'account',
            }
        ],
        [
            'tnc_approval',
            {
                category => 'account',
            }
        ],
        [
            'login_history',
            {
                response => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::login_history_response_handler,
                category => 'account',
            }
        ],
        [
            'set_account_currency',
            {
                before_forward => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::set_account_currency_params_handler,
                category       => 'mt5_hybrid',
            }
        ],
        [
            'set_financial_assessment',
            {
                category => 'account',
            }
        ],
        [
            'get_financial_assessment',
            {
                category => 'account',
            }
        ],
        [
            'reality_check',
            {
                category => 'account',
            }
        ],
        [
            'verify_email',
            {
                stash_params => [qw/ server_name token /],
                category     => 'account',
            }
        ],
        [
            'verify_email_cellxpert',
            {
                stash_params => [qw/ server_name token /],
                category     => 'account',
            }
        ],
        [
            'new_account_virtual',
            {
                stash_params => [qw/ token server_name client_ip user_agent /],
                category     => 'account',
            }
        ],
        [
            'reset_password',
            {
                category => 'account',
            }
        ],
        [
            'change_email',
            {
                stash_params => [qw/ token_type client_ip /],
                category     => 'account',
            }
        ],
        [
            'unsubscribe_email',
            {
                category => 'account',
            }
        ],

        # authenticated calls
        [
            'contract_update',
            {
                success => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::contract_update_handler,
            }
        ],
        ['contract_update_history'],

        [
            'sell',
            {
                category => 'trading',
            }
        ],

        ['cancel'],

        [
            'buy',
            {
                category       => 'trading',
                before_forward => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::buy_get_contract_params,
                success        => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::buy_get_single_contract,
                response       => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::buy_set_poc_subscription_id,
            }
        ],

        [
            'buy_contract_for_multiple_accounts',
            {
                category       => 'trading',
                before_forward => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::buy_get_contract_params,
            }
        ],

        [
            'sell_contract_for_multiple_accounts',
            {
                category => 'trading',
            }
        ],

        [
            'transaction',
            {
                before_forward => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::transaction,
                category       => 'pricing',
            },

        ],
        ['portfolio'],
        [
            'proposal_open_contract',
            {
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::Pricer::proposal_open_contract,
                category        => 'pricing'
            }
        ],

        [
            'sell_expired',
            {
                category => 'trading',
            }
        ],

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

        [
            'topup_virtual',
            {
                category => 'account',
            }
        ],
        [
            'get_limits',
            {
                category => 'mt5_hybrid',
            }
        ],
        [
            'paymentagent_list',
            {
                stash_params => [qw/ token /],
                category     => 'payment',
            }
        ],
        ['payment_methods', {stash_params => [qw/ token /]}],
        [
            'paymentagent_withdraw',
            {
                error        => \&Binary::WebSocketAPI::v3::Wrapper::Cashier::log_paymentagent_error,
                response     => Binary::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('paymentagent_withdraw'),
                stash_params => [qw/ server_name /],
                category     => 'payment',
            }
        ],
        [
            'paymentagent_withdraw_justification',
            {
                category => 'payment',
            }
        ],
        [
            'paymentagent_transfer',
            {
                error        => \&Binary::WebSocketAPI::v3::Wrapper::Cashier::log_paymentagent_error,
                response     => Binary::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('paymentagent_transfer'),
                stash_params => [qw/ server_name /],
                category     => 'payment',
            }
        ],
        [
            'transfer_between_accounts',
            {
                stash_params => [qw/ token_type /],
                error        => \&Binary::WebSocketAPI::v3::Wrapper::Cashier::log_paymentagent_error,
                response     => Binary::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('transfer_between_accounts'),
                category     => 'mt5_hybrid',
            }
        ],
        [
            'paymentagent_details',
            {
                category => 'payment',
            },
        ],
        [
            'paymentagent_create',
            {
                category => 'payment',
            },
        ],
        [
            'cashier',
            {
                stash_params => [qw/ server_name domain /],
                category     => 'payment',
            }
        ],
        [
            'cashier_payments',
            {
                stash_params    => [qw/ server_name domain /],
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::CashierPayments::subscribe_cashier_payments,
                category        => 'payment',
            },
        ],
        [
            'cashier_withdrawal_cancel',
            {
                stash_params => [qw/ server_name domain /],
                category     => 'payment',
            },
        ],
        [
            'new_account_real',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'affiliate_add_person',
            {
                stash_params => [qw/ token server_name client_ip user_agent /],
                category     => 'account',
            }
        ],
        [
            'affiliate_add_company',
            {
                stash_params => [qw/ token server_name client_ip user_agent /],
                category     => 'account',
            }
        ],
        [
            'new_account_maltainvest',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'account_closure',
            {
                category => 'mt5_hybrid',
            },
        ],
        [
            'mt5_login_list',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
                category     => 'mt5',
            }
        ],
        [
            'mt5_new_account',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
                category     => 'mt5',
            }
        ],
        [
            'mt5_deposit',
            {
                response     => Binary::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('mt5_deposit'),
                stash_params => [qw/ server_name client_ip user_agent /],
                category     => 'mt5',
            }
        ],
        [
            'mt5_withdrawal',
            {
                response     => Binary::WebSocketAPI::v3::Wrapper::Cashier::get_response_handler('mt5_withdrawal'),
                stash_params => [qw/ server_name client_ip user_agent /],
                category     => 'mt5',
            }
        ],
        [
            'trading_servers',
            {
                category => 'mt5_hybrid',
            }
        ],
        [
            'document_upload',
            {
                stash_params    => [qw/ token /],
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::DocumentUpload::add_upload_info,
                category        => 'account',
            }
        ],

        ['copytrading_statistics'],
        ['copytrading_list'],
        ['copy_start'],
        ['copy_stop'],

        ['app_markup_details'],
        ['app_markup_statistics'],
        [
            'account_security',
            {
                category => 'account',
            }
        ],
        ['notification_event'],
        [
            'service_token',
            {
                stash_params => [qw/ referrer source_type ua_fingerprint /],
            }
        ],
        # P2P cashier
        [
            'p2p_advert_create',
            {
                category => 'p2p',
            },
        ],
        [
            'p2p_advert_update',
            {
                category => 'p2p',
            },
        ],
        [
            'p2p_advert_info',
            {
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::P2P::subscribe_adverts,
                category        => 'p2p',
            },
        ],
        [
            'p2p_advert_list',
            {
                category => 'p2p',
            },
        ],
        [
            'p2p_order_cancel',
            {
                category => 'p2p',
            },
        ],
        [
            'p2p_order_confirm',
            {
                category => 'p2p',
            },
        ],
        [
            'p2p_order_create',
            {
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::P2P::subscribe_orders,
                category        => 'p2p',
            }
        ],
        [
            'p2p_order_info',
            {
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::P2P::subscribe_orders,
                category        => 'p2p',
            }
        ],
        [
            'p2p_settings',
            {
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::P2P::subscribe_p2p_settings,
                msg_group       => 'p2p',
            }
        ],
        [
            'p2p_order_list',
            {
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::P2P::subscribe_orders,
                category        => 'p2p',
            }
        ],
        [
            'p2p_advertiser_create',
            {
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::P2P::subscribe_advertisers,
                category        => 'p2p',
            }
        ],
        [
            'p2p_advertiser_info',
            {
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::P2P::subscribe_advertisers,
                category        => 'p2p',
            }
        ],
        [
            'p2p_advertiser_update',
            {
                category => 'p2p',
            },
        ],
        [
            'p2p_advertiser_adverts',
            {
                category => 'p2p',
            },
        ],
        [
            'p2p_chat_create',
            {
                category => 'p2p',
            },
        ],
        [
            'p2p_order_dispute',
            {
                category => 'p2p',
            },
        ],
        [
            'p2p_payment_methods',
            {
                category => 'p2p',
            },
        ],
        [
            'p2p_advertiser_payment_methods',
            {
                category => 'p2p',
            },
        ],
        [
            'p2p_advertiser_relations',
            {
                category => 'p2p',
            },
        ],
        [
            'p2p_order_review',
            {
                category => 'p2p',
            },
        ],
        [
            'p2p_ping',
            {
                category => 'p2p',
            },
        ],
        ['trading_platform_asset_listing', {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Streamer::trading_platform_asset_listing}],
        [
            'p2p_advertiser_list',
            {
                category => 'p2p',
            },
        ],
        ['trading_platform_product_listing'],
        ['trading_platform_available_accounts'],
        ['trading_platform_accounts'],
        ['trading_platform_new_account'],
        ['trading_platform_deposit',    {stash_params => [qw/ token_type /]}],
        ['trading_platform_withdrawal', {stash_params => [qw/ token_type /]}],
        [
            'trading_platform_password_change',
            {
                category => 'mt5_hybrid',
            }
        ],
        [
            'trading_platform_password_reset',
            {
                category => 'mt5_hybrid',
            }
        ],
        [
            'trading_platform_investor_password_change',
            {
                category => 'mt5_hybrid',
            }
        ],
        [
            'trading_platform_investor_password_reset',
            {
                category => 'mt5_hybrid',
            }
        ],

        ['new_account_wallet', {stash_params => [qw/ server_name client_ip user_agent /]}],
        ['link_wallet'],
        [
            'get_account_types',
            {
                category => 'account',
            }
        ],
        [
            'get_available_accounts_to_transfer',
            {
                category => 'account',
            }
        ],
        [
            'affiliate_register_person',
            {
                stash_params => [qw/ server_name token /],
                category     => 'account',
            }
        ],
        ['wallet_migration'],
    ];
}

1;
