// AUTO-GENERATED - DO NOT MODIFY BY HAND
// Auto generated from 1st step of the flutter_deriv_api code generation process
// uses collected `msg_type`s from the 1st step to create a helper
// function that maps the `msg_type`s to equivalent Response objects

import '../generated/account_closure_receive.dart';
import '../generated/account_security_receive.dart';
import '../generated/account_statistics_receive.dart';
import '../generated/active_symbols_receive.dart';
import '../generated/api_token_receive.dart';
import '../generated/app_delete_receive.dart';
import '../generated/app_get_receive.dart';
import '../generated/app_list_receive.dart';
import '../generated/app_markup_details_receive.dart';
import '../generated/app_markup_statistics_receive.dart';
import '../generated/app_register_receive.dart';
import '../generated/app_update_receive.dart';
import '../generated/asset_index_receive.dart';
import '../generated/authorize_receive.dart';
import '../generated/available_accounts_receive.dart';
import '../generated/balance_receive.dart';
import '../generated/buy_contract_for_multiple_accounts_receive.dart';
import '../generated/buy_receive.dart';
import '../generated/cancel_receive.dart';
import '../generated/cashier_payments_receive.dart';
import '../generated/cashier_receive.dart';
import '../generated/cashier_withdrawal_cancel_receive.dart';
import '../generated/change_email_receive.dart';
import '../generated/change_password_receive.dart';
import '../generated/contract_update_history_receive.dart';
import '../generated/contract_update_receive.dart';
import '../generated/contracts_for_receive.dart';
import '../generated/copy_start_receive.dart';
import '../generated/copy_stop_receive.dart';
import '../generated/copytrading_list_receive.dart';
import '../generated/copytrading_statistics_receive.dart';
import '../generated/crypto_config_receive.dart';
import '../generated/document_upload_receive.dart';
import '../generated/economic_calendar_receive.dart';
import '../generated/exchange_rates_receive.dart';
import '../generated/forget_all_receive.dart';
import '../generated/forget_receive.dart';
import '../generated/get_account_status_receive.dart';
import '../generated/get_account_types_receive.dart';
import '../generated/get_financial_assessment_receive.dart';
import '../generated/get_limits_receive.dart';
import '../generated/get_self_exclusion_receive.dart';
import '../generated/get_settings_receive.dart';
import '../generated/identity_verification_document_add_receive.dart';
import '../generated/landing_company_details_receive.dart';
import '../generated/landing_company_receive.dart';
import '../generated/link_wallet_receive.dart';
import '../generated/login_history_receive.dart';
import '../generated/logout_receive.dart';
import '../generated/mt5_deposit_receive.dart';
import '../generated/mt5_get_settings_receive.dart';
import '../generated/mt5_login_list_receive.dart';
import '../generated/mt5_new_account_receive.dart';
import '../generated/mt5_password_change_receive.dart';
import '../generated/mt5_password_check_receive.dart';
import '../generated/mt5_password_reset_receive.dart';
import '../generated/mt5_withdrawal_receive.dart';
import '../generated/new_account_maltainvest_receive.dart';
import '../generated/new_account_real_receive.dart';
import '../generated/new_account_virtual_receive.dart';
import '../generated/new_account_wallet_receive.dart';
import '../generated/notification_event_receive.dart';
import '../generated/oauth_apps_receive.dart';
import '../generated/p2p_advert_create_receive.dart';
import '../generated/p2p_advert_info_receive.dart';
import '../generated/p2p_advert_list_receive.dart';
import '../generated/p2p_advert_update_receive.dart';
import '../generated/p2p_advertiser_adverts_receive.dart';
import '../generated/p2p_advertiser_create_receive.dart';
import '../generated/p2p_advertiser_info_receive.dart';
import '../generated/p2p_advertiser_list_receive.dart';
import '../generated/p2p_advertiser_payment_methods_receive.dart';
import '../generated/p2p_advertiser_relations_receive.dart';
import '../generated/p2p_advertiser_update_receive.dart';
import '../generated/p2p_chat_create_receive.dart';
import '../generated/p2p_order_cancel_receive.dart';
import '../generated/p2p_order_confirm_receive.dart';
import '../generated/p2p_order_create_receive.dart';
import '../generated/p2p_order_dispute_receive.dart';
import '../generated/p2p_order_info_receive.dart';
import '../generated/p2p_order_list_receive.dart';
import '../generated/p2p_order_review_receive.dart';
import '../generated/p2p_payment_methods_receive.dart';
import '../generated/p2p_ping_receive.dart';
import '../generated/p2p_settings_receive.dart';
import '../generated/payment_methods_receive.dart';
import '../generated/paymentagent_create_receive.dart';
import '../generated/paymentagent_details_receive.dart';
import '../generated/paymentagent_list_receive.dart';
import '../generated/paymentagent_transfer_receive.dart';
import '../generated/paymentagent_withdraw_receive.dart';
import '../generated/payout_currencies_receive.dart';
import '../generated/ping_receive.dart';
import '../generated/portfolio_receive.dart';
import '../generated/profit_table_receive.dart';
import '../generated/proposal_open_contract_receive.dart';
import '../generated/proposal_receive.dart';
import '../generated/reality_check_receive.dart';
import '../generated/request_report_receive.dart';
import '../generated/reset_password_receive.dart';
import '../generated/residence_list_receive.dart';
import '../generated/revoke_oauth_app_receive.dart';
import '../generated/sell_contract_for_multiple_accounts_receive.dart';
import '../generated/sell_expired_receive.dart';
import '../generated/sell_receive.dart';
import '../generated/service_token_receive.dart';
import '../generated/set_account_currency_receive.dart';
import '../generated/set_financial_assessment_receive.dart';
import '../generated/set_self_exclusion_receive.dart';
import '../generated/set_settings_receive.dart';
import '../generated/statement_receive.dart';
import '../generated/states_list_receive.dart';
import '../generated/ticks_history_receive.dart';
import '../generated/ticks_receive.dart';
import '../generated/time_receive.dart';
import '../generated/tnc_approval_receive.dart';
import '../generated/topup_virtual_receive.dart';
import '../generated/trading_durations_receive.dart';
import '../generated/trading_platform_accounts_receive.dart';
import '../generated/trading_platform_asset_listing_receive.dart';
import '../generated/trading_platform_available_accounts_receive.dart';
import '../generated/trading_platform_deposit_receive.dart';
import '../generated/trading_platform_investor_password_change_receive.dart';
import '../generated/trading_platform_investor_password_reset_receive.dart';
import '../generated/trading_platform_new_account_receive.dart';
import '../generated/trading_platform_password_change_receive.dart';
import '../generated/trading_platform_password_reset_receive.dart';
import '../generated/trading_platform_product_listing_receive.dart';
import '../generated/trading_platform_withdrawal_receive.dart';
import '../generated/trading_servers_receive.dart';
import '../generated/trading_times_receive.dart';
import '../generated/transaction_receive.dart';
import '../generated/transfer_between_accounts_receive.dart';
import '../generated/unsubscribe_email_receive.dart';
import '../generated/verify_email_cellxpert_receive.dart';
import '../generated/verify_email_receive.dart';
import '../generated/wallet_migration_receive.dart';
import '../generated/website_status_receive.dart';
import '../response.dart';

/// A function that create a sub-type of [Response] based on
/// [responseMap]'s 'msg_type'
Response getGeneratedResponse(Map<String, dynamic> responseMap) {
  switch (responseMap['msg_type']) {
    case 'account_closure':
      return AccountClosureReceive.fromJson(responseMap);
    case 'account_security':
      return AccountSecurityReceive.fromJson(responseMap);
    case 'account_statistics':
      return AccountStatisticsReceive.fromJson(responseMap);
    case 'active_symbols':
      return ActiveSymbolsReceive.fromJson(responseMap);
    case 'api_token':
      return ApiTokenReceive.fromJson(responseMap);
    case 'app_delete':
      return AppDeleteReceive.fromJson(responseMap);
    case 'app_get':
      return AppGetReceive.fromJson(responseMap);
    case 'app_list':
      return AppListReceive.fromJson(responseMap);
    case 'app_markup_details':
      return AppMarkupDetailsReceive.fromJson(responseMap);
    case 'app_markup_statistics':
      return AppMarkupStatisticsReceive.fromJson(responseMap);
    case 'app_register':
      return AppRegisterReceive.fromJson(responseMap);
    case 'app_update':
      return AppUpdateReceive.fromJson(responseMap);
    case 'asset_index':
      return AssetIndexReceive.fromJson(responseMap);
    case 'authorize':
      return AuthorizeReceive.fromJson(responseMap);
    case 'available_accounts':
      return AvailableAccountsReceive.fromJson(responseMap);
    case 'balance':
      return BalanceReceive.fromJson(responseMap);
    case 'buy_contract_for_multiple_accounts':
      return BuyContractForMultipleAccountsReceive.fromJson(responseMap);
    case 'buy':
      return BuyReceive.fromJson(responseMap);
    case 'cancel':
      return CancelReceive.fromJson(responseMap);
    case 'cashier_payments':
      return CashierPaymentsReceive.fromJson(responseMap);
    case 'cashier':
      return CashierReceive.fromJson(responseMap);
    case 'cashier_withdrawal_cancel':
      return CashierWithdrawalCancelReceive.fromJson(responseMap);
    case 'change_email':
      return ChangeEmailReceive.fromJson(responseMap);
    case 'change_password':
      return ChangePasswordReceive.fromJson(responseMap);
    case 'contract_update_history':
      return ContractUpdateHistoryReceive.fromJson(responseMap);
    case 'contract_update':
      return ContractUpdateReceive.fromJson(responseMap);
    case 'contracts_for':
      return ContractsForReceive.fromJson(responseMap);
    case 'copy_start':
      return CopyStartReceive.fromJson(responseMap);
    case 'copy_stop':
      return CopyStopReceive.fromJson(responseMap);
    case 'copytrading_list':
      return CopytradingListReceive.fromJson(responseMap);
    case 'copytrading_statistics':
      return CopytradingStatisticsReceive.fromJson(responseMap);
    case 'crypto_config':
      return CryptoConfigReceive.fromJson(responseMap);
    case 'document_upload':
      return DocumentUploadReceive.fromJson(responseMap);
    case 'economic_calendar':
      return EconomicCalendarReceive.fromJson(responseMap);
    case 'exchange_rates':
      return ExchangeRatesReceive.fromJson(responseMap);
    case 'forget_all':
      return ForgetAllReceive.fromJson(responseMap);
    case 'forget':
      return ForgetReceive.fromJson(responseMap);
    case 'get_account_status':
      return GetAccountStatusReceive.fromJson(responseMap);
    case 'get_account_types':
      return GetAccountTypesReceive.fromJson(responseMap);
    case 'get_financial_assessment':
      return GetFinancialAssessmentReceive.fromJson(responseMap);
    case 'get_limits':
      return GetLimitsReceive.fromJson(responseMap);
    case 'get_self_exclusion':
      return GetSelfExclusionReceive.fromJson(responseMap);
    case 'get_settings':
      return GetSettingsReceive.fromJson(responseMap);
    case 'identity_verification_document_add':
      return IdentityVerificationDocumentAddReceive.fromJson(responseMap);
    case 'landing_company_details':
      return LandingCompanyDetailsReceive.fromJson(responseMap);
    case 'landing_company':
      return LandingCompanyReceive.fromJson(responseMap);
    case 'link_wallet':
      return LinkWalletReceive.fromJson(responseMap);
    case 'login_history':
      return LoginHistoryReceive.fromJson(responseMap);
    case 'logout':
      return LogoutReceive.fromJson(responseMap);
    case 'mt5_deposit':
      return Mt5DepositReceive.fromJson(responseMap);
    case 'mt5_get_settings':
      return Mt5GetSettingsReceive.fromJson(responseMap);
    case 'mt5_login_list':
      return Mt5LoginListReceive.fromJson(responseMap);
    case 'mt5_new_account':
      return Mt5NewAccountReceive.fromJson(responseMap);
    case 'mt5_password_change':
      return Mt5PasswordChangeReceive.fromJson(responseMap);
    case 'mt5_password_check':
      return Mt5PasswordCheckReceive.fromJson(responseMap);
    case 'mt5_password_reset':
      return Mt5PasswordResetReceive.fromJson(responseMap);
    case 'mt5_withdrawal':
      return Mt5WithdrawalReceive.fromJson(responseMap);
    case 'new_account_maltainvest':
      return NewAccountMaltainvestReceive.fromJson(responseMap);
    case 'new_account_real':
      return NewAccountRealReceive.fromJson(responseMap);
    case 'new_account_virtual':
      return NewAccountVirtualReceive.fromJson(responseMap);
    case 'new_account_wallet':
      return NewAccountWalletReceive.fromJson(responseMap);
    case 'notification_event':
      return NotificationEventReceive.fromJson(responseMap);
    case 'oauth_apps':
      return OauthAppsReceive.fromJson(responseMap);
    case 'p2p_advert_create':
      return P2pAdvertCreateReceive.fromJson(responseMap);
    case 'p2p_advert_info':
      return P2pAdvertInfoReceive.fromJson(responseMap);
    case 'p2p_advert_list':
      return P2pAdvertListReceive.fromJson(responseMap);
    case 'p2p_advert_update':
      return P2pAdvertUpdateReceive.fromJson(responseMap);
    case 'p2p_advertiser_adverts':
      return P2pAdvertiserAdvertsReceive.fromJson(responseMap);
    case 'p2p_advertiser_create':
      return P2pAdvertiserCreateReceive.fromJson(responseMap);
    case 'p2p_advertiser_info':
      return P2pAdvertiserInfoReceive.fromJson(responseMap);
    case 'p2p_advertiser_list':
      return P2pAdvertiserListReceive.fromJson(responseMap);
    case 'p2p_advertiser_payment_methods':
      return P2pAdvertiserPaymentMethodsReceive.fromJson(responseMap);
    case 'p2p_advertiser_relations':
      return P2pAdvertiserRelationsReceive.fromJson(responseMap);
    case 'p2p_advertiser_update':
      return P2pAdvertiserUpdateReceive.fromJson(responseMap);
    case 'p2p_chat_create':
      return P2pChatCreateReceive.fromJson(responseMap);
    case 'p2p_order_cancel':
      return P2pOrderCancelReceive.fromJson(responseMap);
    case 'p2p_order_confirm':
      return P2pOrderConfirmReceive.fromJson(responseMap);
    case 'p2p_order_create':
      return P2pOrderCreateReceive.fromJson(responseMap);
    case 'p2p_order_dispute':
      return P2pOrderDisputeReceive.fromJson(responseMap);
    case 'p2p_order_info':
      return P2pOrderInfoReceive.fromJson(responseMap);
    case 'p2p_order_list':
      return P2pOrderListReceive.fromJson(responseMap);
    case 'p2p_order_review':
      return P2pOrderReviewReceive.fromJson(responseMap);
    case 'p2p_payment_methods':
      return P2pPaymentMethodsReceive.fromJson(responseMap);
    case 'p2p_ping':
      return P2pPingReceive.fromJson(responseMap);
    case 'p2p_settings':
      return P2pSettingsReceive.fromJson(responseMap);
    case 'payment_methods':
      return PaymentMethodsReceive.fromJson(responseMap);
    case 'paymentagent_create':
      return PaymentagentCreateReceive.fromJson(responseMap);
    case 'paymentagent_details':
      return PaymentagentDetailsReceive.fromJson(responseMap);
    case 'paymentagent_list':
      return PaymentagentListReceive.fromJson(responseMap);
    case 'paymentagent_transfer':
      return PaymentagentTransferReceive.fromJson(responseMap);
    case 'paymentagent_withdraw':
      return PaymentagentWithdrawReceive.fromJson(responseMap);
    case 'payout_currencies':
      return PayoutCurrenciesReceive.fromJson(responseMap);
    case 'ping':
      return PingReceive.fromJson(responseMap);
    case 'portfolio':
      return PortfolioReceive.fromJson(responseMap);
    case 'profit_table':
      return ProfitTableReceive.fromJson(responseMap);
    case 'proposal_open_contract':
      return ProposalOpenContractReceive.fromJson(responseMap);
    case 'proposal':
      return ProposalReceive.fromJson(responseMap);
    case 'reality_check':
      return RealityCheckReceive.fromJson(responseMap);
    case 'request_report':
      return RequestReportReceive.fromJson(responseMap);
    case 'reset_password':
      return ResetPasswordReceive.fromJson(responseMap);
    case 'residence_list':
      return ResidenceListReceive.fromJson(responseMap);
    case 'revoke_oauth_app':
      return RevokeOauthAppReceive.fromJson(responseMap);
    case 'sell_contract_for_multiple_accounts':
      return SellContractForMultipleAccountsReceive.fromJson(responseMap);
    case 'sell_expired':
      return SellExpiredReceive.fromJson(responseMap);
    case 'sell':
      return SellReceive.fromJson(responseMap);
    case 'service_token':
      return ServiceTokenReceive.fromJson(responseMap);
    case 'set_account_currency':
      return SetAccountCurrencyReceive.fromJson(responseMap);
    case 'set_financial_assessment':
      return SetFinancialAssessmentReceive.fromJson(responseMap);
    case 'set_self_exclusion':
      return SetSelfExclusionReceive.fromJson(responseMap);
    case 'set_settings':
      return SetSettingsReceive.fromJson(responseMap);
    case 'statement':
      return StatementReceive.fromJson(responseMap);
    case 'states_list':
      return StatesListReceive.fromJson(responseMap);
    case 'history':
      return TicksHistoryReceive.fromJson(responseMap);
    case 'tick':
      return TicksReceive.fromJson(responseMap);
    case 'time':
      return TimeReceive.fromJson(responseMap);
    case 'tnc_approval':
      return TncApprovalReceive.fromJson(responseMap);
    case 'topup_virtual':
      return TopupVirtualReceive.fromJson(responseMap);
    case 'trading_durations':
      return TradingDurationsReceive.fromJson(responseMap);
    case 'trading_platform_accounts':
      return TradingPlatformAccountsReceive.fromJson(responseMap);
    case 'trading_platform_asset_listing':
      return TradingPlatformAssetListingReceive.fromJson(responseMap);
    case 'trading_platform_available_accounts':
      return TradingPlatformAvailableAccountsReceive.fromJson(responseMap);
    case 'trading_platform_deposit':
      return TradingPlatformDepositReceive.fromJson(responseMap);
    case 'trading_platform_investor_password_change':
      return TradingPlatformInvestorPasswordChangeReceive.fromJson(responseMap);
    case 'trading_platform_investor_password_reset':
      return TradingPlatformInvestorPasswordResetReceive.fromJson(responseMap);
    case 'trading_platform_new_account':
      return TradingPlatformNewAccountReceive.fromJson(responseMap);
    case 'trading_platform_password_change':
      return TradingPlatformPasswordChangeReceive.fromJson(responseMap);
    case 'trading_platform_password_reset':
      return TradingPlatformPasswordResetReceive.fromJson(responseMap);
    case 'trading_platform_product_listing':
      return TradingPlatformProductListingReceive.fromJson(responseMap);
    case 'trading_platform_withdrawal':
      return TradingPlatformWithdrawalReceive.fromJson(responseMap);
    case 'trading_servers':
      return TradingServersReceive.fromJson(responseMap);
    case 'trading_times':
      return TradingTimesReceive.fromJson(responseMap);
    case 'transaction':
      return TransactionReceive.fromJson(responseMap);
    case 'transfer_between_accounts':
      return TransferBetweenAccountsReceive.fromJson(responseMap);
    case 'unsubscribe_email':
      return UnsubscribeEmailReceive.fromJson(responseMap);
    case 'verify_email_cellxpert':
      return VerifyEmailCellxpertReceive.fromJson(responseMap);
    case 'verify_email':
      return VerifyEmailReceive.fromJson(responseMap);
    case 'wallet_migration':
      return WalletMigrationReceive.fromJson(responseMap);
    case 'website_status':
      return WebsiteStatusReceive.fromJson(responseMap);

    default:
      return Response.fromJson(responseMap);
  }
}
