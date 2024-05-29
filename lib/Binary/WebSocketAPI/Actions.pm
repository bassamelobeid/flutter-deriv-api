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
            'account_closure',
            {
                category => 'mt5_hybrid',
            },
        ],
        [
            'account_list',
            {
                category => 'account',
            }
        ],
        [
            'account_security',
            {
                category => 'account',
            }
        ],
        [
            'account_statistics',
            {
                category => 'account',
            }
        ],
        ['active_symbols', {stash_params => [qw/ token account_tokens /]}],
        [
            'affiliate_add_company',
            {
                stash_params => [qw/ token account_tokens server_name client_ip user_agent /],
                category     => 'account',
            }
        ],
        [
            'affiliate_add_person',
            {
                stash_params => [qw/ token account_tokens server_name client_ip user_agent /],
                category     => 'account',
            }
        ],
        [
            'affiliate_register_person',
            {
                stash_params => [qw/ server_name token account_tokens /],
                category     => 'account',
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
            'app_delete',
            {
                success => \&Binary::WebSocketAPI::v3::Wrapper::App::block_app_id,
            }
        ],
        ['app_get'],
        ['app_list'],
        ['app_markup_details'],
        ['app_markup_statistics'],
        ['app_register'],
        ['app_update'],
        ['asset_index', {stash_params => [qw/ token account_tokens /]}],
        [
            'authorize',
            {
                stash_params => [qw/ ua_fingerprint client_ip user_agent /],
                success      => \&Binary::WebSocketAPI::v3::Wrapper::Authorize::login_success,
                category     => 'account',
            }
        ],
        [
            'available_accounts',
            {
                category => 'account',
            }
        ],
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
        ['cancel'],
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
            'change_email',
            {
                stash_params => [qw/ token_type client_ip /],
                category     => 'account',
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
            'confirm_email',
            {
                stash_params => [qw/ server_name account_tokens /],
                category     => 'account',
            }
        ],
        [
            'contract_update',
            {
                success => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::contract_update_handler,
            }
        ],
        ['contract_update_history'],
        ['contracts_for', {stash_params => [qw/ token account_tokens /]}],
        ['copy_start'],
        ['copy_stop'],
        ['copytrading_list'],
        ['copytrading_statistics'],
        ['crypto_config', {stash_params => [qw/ token account_tokens /]}],
        [
            'crypto_estimations',
            {
                instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Streamer::crypto_estimations,
                category           => 'crypto_cashier',
            },
        ],
        [
            'document_upload',
            {
                stash_params    => [qw/ token account_tokens /],
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::DocumentUpload::add_upload_info,
                category        => 'account',
            }
        ],
        ['economic_calendar'],
        [
            'exchange_rates',
            {
                instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Streamer::exchange_rates,
                allow_rest         => 1
            }
        ],
        ['forget',     {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::System::forget}],
        ['forget_all', {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::System::forget_all}],
        [
            'get_account_status',
            {
                category => 'mt5_hybrid',
            }
        ],
        [
            'get_account_types',
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
            'get_limits',
            {
                category => 'mt5_hybrid',
            }
        ],
        [
            'get_self_exclusion',
            {
                category => 'account',
            }
        ],
        [
            'get_settings',
            {
                category => 'account',
            }
        ],
        ['identity_verification_document_add'],
        ['jtoken_create'],
        [
            'kyc_auth_status',
            {
                category => 'mt5_hybrid',
            }
        ],
        ['landing_company'],
        ['landing_company_details'],
        ['link_wallet'],
        [
            'login_history',
            {
                response => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::login_history_response_handler,
                category => 'account',
            }
        ],
        [
            'logout',
            {
                stash_params => [qw/ token account_tokens token_type email client_ip user_agent /],
                success      => \&Binary::WebSocketAPI::v3::Wrapper::Authorize::logout_success,
                category     => 'account',
            },
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
            'mt5_get_settings',
            {
                category => 'mt5',
            }
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
            'mt5_password_change',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
                category     => 'mt5',
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
            'mt5_password_reset',
            {
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
            'new_account_maltainvest',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'new_account_real',
            {
                stash_params => [qw/ server_name client_ip user_agent /],
            }
        ],
        [
            'new_account_virtual',
            {
                stash_params => [qw/ token account_tokens server_name client_ip user_agent /],
                category     => 'account',
            }
        ],
        ['new_account_wallet', {stash_params => [qw/ server_name client_ip user_agent /]}],
        ['notification_event'],
        ['oauth_apps'],
        [
            'p2p_advert_create',
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
            'p2p_advert_update',
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
            'p2p_advertiser_list',
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
            'p2p_advertiser_update',
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
            'p2p_country_list',
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
            'p2p_order_dispute',
            {
                category => 'p2p',
            },
        ],
        [
            'p2p_order_info',
            {
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::P2P::subscribe_orders,
                category        => 'p2p',
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
            'p2p_order_review',
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
            'p2p_ping',
            {
                category => 'p2p',
            },
        ],
        [
            'p2p_settings',
            {
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::P2P::subscribe_p2p_settings,
                msg_group       => 'p2p',
            }
        ],
        [
            'passkeys_list',
            {
                category           => 'passkeys',
                stash_params       => [qw/ jtoken client_ip user_agent domain /],
                instead_of_forward => \&Binary::WebSocketAPI::Hooks::add_jtoken_to_stash,
            }
        ],
        [
            'passkeys_login',
            {
                category     => 'passkeys',
                stash_params => [qw/ client_ip user_agent domain /],
            }
        ],
        [
            'passkeys_options',
            {
                category           => 'passkeys',
                stash_params       => [qw/ jtoken client_ip user_agent domain /],
                instead_of_forward => \&Binary::WebSocketAPI::Hooks::add_jtoken_to_stash,
            }
        ],
        [
            'passkeys_register',
            {
                category           => 'passkeys',
                stash_params       => [qw/ jtoken client_ip user_agent domain /],
                instead_of_forward => \&Binary::WebSocketAPI::Hooks::add_jtoken_to_stash,
            }
        ],
        [
            'passkeys_register_options',
            {
                category           => 'passkeys',
                stash_params       => [qw/ jtoken client_ip user_agent domain /],
                instead_of_forward => \&Binary::WebSocketAPI::Hooks::add_jtoken_to_stash,
            }
        ],
        [
            'passkeys_rename',
            {
                category           => 'passkeys',
                stash_params       => [qw/ jtoken client_ip user_agent domain /],
                instead_of_forward => \&Binary::WebSocketAPI::Hooks::add_jtoken_to_stash,
            }
        ],
        [
            'passkeys_revoke',
            {
                category           => 'passkeys',
                stash_params       => [qw/ jtoken client_ip user_agent domain /],
                instead_of_forward => \&Binary::WebSocketAPI::Hooks::add_jtoken_to_stash,
            }
        ],
        ['payment_methods', {stash_params => [qw/ token account_tokens /]}],
        [
            'paymentagent_create',
            {
                category => 'payment',
            },
        ],
        [
            'paymentagent_details',
            {
                category => 'payment',
            },
        ],
        [
            'paymentagent_list',
            {
                stash_params => [qw/ token account_tokens /],
                category     => 'payment',
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
        ['payout_currencies', {stash_params => [qw/ token account_tokens landing_company_name /]}],
        ['phone_number_challenge'],
        ['phone_number_verify'],
        ['ping', {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::System::ping}],
        ['portfolio'],
        ['profit_table'],
        [
            'proposal',
            {
                instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Pricer::proposal,
                category           => 'pricing'
            }
        ],
        [
            'proposal_open_contract',
            {
                rpc_response_cb => \&Binary::WebSocketAPI::v3::Wrapper::Pricer::proposal_open_contract,
                category        => 'pricing'
            }
        ],
        [
            'reality_check',
            {
                category => 'account',
            }
        ],
        ['request_report'],
        [
            'reset_password',
            {
                category => 'account',
            }
        ],
        ['residence_list', {allow_rest => 1}],
        ['revoke_oauth_app'],
        [
            'sell',
            {
                category => 'trading',
            }
        ],
        [
            'sell_contract_for_multiple_accounts',
            {
                category => 'trading',
            }
        ],
        [
            'sell_expired',
            {
                category => 'trading',
            }
        ],
        [
            'service_token',
            {
                stash_params => [qw/ referrer source_type ua_fingerprint /],
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
            'set_self_exclusion',
            {
                response => \&Binary::WebSocketAPI::v3::Wrapper::Accounts::set_self_exclusion_response_handler,
                category => 'mt5_hybrid',
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
            'statement',
            {
                category => 'mt5_hybrid',
            }
        ],
        ['states_list'],
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
        ['time', {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::System::server_time}],
        [
            'tnc_approval',
            {
                category => 'account',
            }
        ],
        [
            'topup_virtual',
            {
                category => 'account',
            }
        ],
        ['trading_durations', {stash_params => [qw/ token account_tokens /]}],
        ['trading_platform_accounts'],
        ['trading_platform_asset_listing', {instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Streamer::trading_platform_asset_listing}],
        ['trading_platform_available_accounts', {stash_params => [qw/ token /]}],
        ['trading_platform_deposit',            {stash_params => [qw/ token_type /]}],
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
        [
            'trading_platform_leverage',
            {
                category => 'trading_platform_leverage',
            }
        ],
        ['trading_platform_new_account'],
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
        ['trading_platform_product_listing'],
        ['trading_platform_withdrawal', {stash_params => [qw/ token_type /]}],
        ['trading_platforms'],
        [
            'trading_servers',
            {
                category => 'mt5_hybrid',
            }
        ],
        ['trading_times'],
        [
            'transaction',
            {
                before_forward => \&Binary::WebSocketAPI::v3::Wrapper::Transaction::transaction,
                category       => 'pricing',
            },
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
            'unsubscribe_email',
            {
                category => 'account',
            }
        ],
        [
            'verify_email',
            {
                stash_params => [qw/ server_name token account_tokens /],
                category     => 'account',
            }
        ],
        [
            'verify_email_cellxpert',
            {
                stash_params => [qw/ server_name token account_tokens /],
                category     => 'account',
            }
        ],
        ['wallet_migration'],
        [
            'website_config',
            {
                category => 'account',
            }
        ],
        [
            'website_status',
            {
                instead_of_forward => \&Binary::WebSocketAPI::v3::Wrapper::Streamer::website_status,
                allow_rest         => 1
            }
        ],
    ];
}

1;
