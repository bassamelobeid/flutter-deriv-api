// AUTO-GENERATED - DO NOT MODIFY BY HAND
// Auto generated from 1st step of the flutter_deriv_api code generation process
// uses collected `msg_type`s from the 1st step to create a helper
// function that maps the `msg_type`s to equivalent Response objects

import 'account_closure_receive.dart';
import 'account_security_receive.dart';
import 'account_statistics_receive.dart';
import 'active_symbols_receive.dart';
import 'api_token_receive.dart';
import 'app_delete_receive.dart';
import 'app_get_receive.dart';
import 'app_list_receive.dart';
import 'app_markup_details_receive.dart';
import 'app_register_receive.dart';
import 'app_update_receive.dart';
import 'asset_index_receive.dart';
import 'authorize_receive.dart';
import 'balance_receive.dart';
import 'buy_contract_for_multiple_accounts_receive.dart';
import 'buy_receive.dart';
import 'cancel_receive.dart';
import 'cashier_receive.dart';
import 'change_password_receive.dart';
import 'contract_update_history_receive.dart';
import 'contract_update_receive.dart';
import 'contracts_for_receive.dart';
import 'copy_start_receive.dart';
import 'copy_stop_receive.dart';
import 'copytrading_list_receive.dart';
import 'copytrading_statistics_receive.dart';
import 'document_upload_receive.dart';
import 'exchange_rates_receive.dart';
import 'forget_all_receive.dart';
import 'forget_receive.dart';
import 'get_account_status_receive.dart';
import 'get_financial_assessment_receive.dart';
import 'get_limits_receive.dart';
import 'get_self_exclusion_receive.dart';
import 'get_settings_receive.dart';
import 'landing_company_details_receive.dart';
import 'landing_company_receive.dart';
import 'login_history_receive.dart';
import 'logout_receive.dart';
import 'mt5_deposit_receive.dart';
import 'mt5_get_settings_receive.dart';
import 'mt5_login_list_receive.dart';
import 'mt5_new_account_receive.dart';
import 'mt5_password_change_receive.dart';
import 'mt5_password_check_receive.dart';
import 'mt5_password_reset_receive.dart';
import 'mt5_withdrawal_receive.dart';
import 'new_account_maltainvest_receive.dart';
import 'new_account_real_receive.dart';
import 'new_account_virtual_receive.dart';
import 'notification_event_receive.dart';
import 'oauth_apps_receive.dart';
import 'p2p_advert_create_receive.dart';
import 'p2p_advert_info_receive.dart';
import 'p2p_advert_list_receive.dart';
import 'p2p_advert_update_receive.dart';
import 'p2p_advertiser_adverts_receive.dart';
import 'p2p_advertiser_create_receive.dart';
import 'p2p_advertiser_info_receive.dart';
import 'p2p_advertiser_update_receive.dart';
import 'p2p_chat_create_receive.dart';
import 'p2p_order_cancel_receive.dart';
import 'p2p_order_confirm_receive.dart';
import 'p2p_order_create_receive.dart';
import 'p2p_order_info_receive.dart';
import 'p2p_order_list_receive.dart';
import 'paymentagent_list_receive.dart';
import 'paymentagent_transfer_receive.dart';
import 'paymentagent_withdraw_receive.dart';
import 'payout_currencies_receive.dart';
import 'ping_receive.dart';
import 'portfolio_receive.dart';
import 'profit_table_receive.dart';
import 'proposal_array_receive.dart';
import 'proposal_open_contract_receive.dart';
import 'proposal_receive.dart';
import 'reality_check_receive.dart';
import 'request_report_receive.dart';
import 'reset_password_receive.dart';
import 'residence_list_receive.dart';
import 'response.dart';
import 'revoke_oauth_app_receive.dart';
import 'sell_contract_for_multiple_accounts_receive.dart';
import 'sell_expired_receive.dart';
import 'sell_receive.dart';
import 'service_token_receive.dart';
import 'set_account_currency_receive.dart';
import 'set_financial_assessment_receive.dart';
import 'set_self_exclusion_receive.dart';
import 'set_settings_receive.dart';
import 'statement_receive.dart';
import 'states_list_receive.dart';
import 'ticks_history_receive.dart';
import 'ticks_receive.dart';
import 'time_receive.dart';
import 'tnc_approval_receive.dart';
import 'topup_virtual_receive.dart';
import 'trading_durations_receive.dart';
import 'trading_times_receive.dart';
import 'transaction_receive.dart';
import 'transfer_between_accounts_receive.dart';
import 'verify_email_receive.dart';
import 'website_status_receive.dart';

/// A function that create a sub-type of [Response] based on
/// [responseMap]'s 'msg_type'
Response getResponseByMsgType(Map<String, dynamic> responseMap) {
  switch (responseMap['msg_type']) {
    case 'account_closure':
      return AccountClosureResponse.fromJson(responseMap);
    case 'account_security':
      return AccountSecurityResponse.fromJson(responseMap);
    case 'account_statistics':
      return AccountStatisticsResponse.fromJson(responseMap);
    case 'active_symbols':
      return ActiveSymbolsResponse.fromJson(responseMap);
    case 'api_token':
      return ApiTokenResponse.fromJson(responseMap);
    case 'app_delete':
      return AppDeleteResponse.fromJson(responseMap);
    case 'app_get':
      return AppGetResponse.fromJson(responseMap);
    case 'app_list':
      return AppListResponse.fromJson(responseMap);
    case 'app_markup_details':
      return AppMarkupDetailsResponse.fromJson(responseMap);
    case 'app_register':
      return AppRegisterResponse.fromJson(responseMap);
    case 'app_update':
      return AppUpdateResponse.fromJson(responseMap);
    case 'asset_index':
      return AssetIndexResponse.fromJson(responseMap);
    case 'authorize':
      return AuthorizeResponse.fromJson(responseMap);
    case 'balance':
      return BalanceResponse.fromJson(responseMap);
    case 'buy_contract_for_multiple_accounts':
      return BuyContractForMultipleAccountsResponse.fromJson(responseMap);
    case 'buy':
      return BuyResponse.fromJson(responseMap);
    case 'cancel':
      return CancelResponse.fromJson(responseMap);
    case 'cashier':
      return CashierResponse.fromJson(responseMap);
    case 'change_password':
      return ChangePasswordResponse.fromJson(responseMap);
    case 'contract_update_history':
      return ContractUpdateHistoryResponse.fromJson(responseMap);
    case 'contract_update':
      return ContractUpdateResponse.fromJson(responseMap);
    case 'contracts_for':
      return ContractsForResponse.fromJson(responseMap);
    case 'copy_start':
      return CopyStartResponse.fromJson(responseMap);
    case 'copy_stop':
      return CopyStopResponse.fromJson(responseMap);
    case 'copytrading_list':
      return CopytradingListResponse.fromJson(responseMap);
    case 'copytrading_statistics':
      return CopytradingStatisticsResponse.fromJson(responseMap);
    case 'document_upload':
      return DocumentUploadResponse.fromJson(responseMap);
    case 'exchange_rates':
      return ExchangeRatesResponse.fromJson(responseMap);
    case 'forget_all':
      return ForgetAllResponse.fromJson(responseMap);
    case 'forget':
      return ForgetResponse.fromJson(responseMap);
    case 'get_account_status':
      return GetAccountStatusResponse.fromJson(responseMap);
    case 'get_financial_assessment':
      return GetFinancialAssessmentResponse.fromJson(responseMap);
    case 'get_limits':
      return GetLimitsResponse.fromJson(responseMap);
    case 'get_self_exclusion':
      return GetSelfExclusionResponse.fromJson(responseMap);
    case 'get_settings':
      return GetSettingsResponse.fromJson(responseMap);
    case 'landing_company_details':
      return LandingCompanyDetailsResponse.fromJson(responseMap);
    case 'landing_company':
      return LandingCompanyResponse.fromJson(responseMap);
    case 'login_history':
      return LoginHistoryResponse.fromJson(responseMap);
    case 'logout':
      return LogoutResponse.fromJson(responseMap);
    case 'mt5_deposit':
      return Mt5DepositResponse.fromJson(responseMap);
    case 'mt5_get_settings':
      return Mt5GetSettingsResponse.fromJson(responseMap);
    case 'mt5_login_list':
      return Mt5LoginListResponse.fromJson(responseMap);
    case 'mt5_new_account':
      return Mt5NewAccountResponse.fromJson(responseMap);
    case 'mt5_password_change':
      return Mt5PasswordChangeResponse.fromJson(responseMap);
    case 'mt5_password_check':
      return Mt5PasswordCheckResponse.fromJson(responseMap);
    case 'mt5_password_reset':
      return Mt5PasswordResetResponse.fromJson(responseMap);
    case 'mt5_withdrawal':
      return Mt5WithdrawalResponse.fromJson(responseMap);
    case 'new_account_maltainvest':
      return NewAccountMaltainvestResponse.fromJson(responseMap);
    case 'new_account_real':
      return NewAccountRealResponse.fromJson(responseMap);
    case 'new_account_virtual':
      return NewAccountVirtualResponse.fromJson(responseMap);
    case 'notification_event':
      return NotificationEventResponse.fromJson(responseMap);
    case 'oauth_apps':
      return OauthAppsResponse.fromJson(responseMap);
    case 'p2p_advert_create':
      return P2pAdvertCreateResponse.fromJson(responseMap);
    case 'p2p_advert_info':
      return P2pAdvertInfoResponse.fromJson(responseMap);
    case 'p2p_advert_list':
      return P2pAdvertListResponse.fromJson(responseMap);
    case 'p2p_advert_update':
      return P2pAdvertUpdateResponse.fromJson(responseMap);
    case 'p2p_advertiser_adverts':
      return P2pAdvertiserAdvertsResponse.fromJson(responseMap);
    case 'p2p_advertiser_create':
      return P2pAdvertiserCreateResponse.fromJson(responseMap);
    case 'p2p_advertiser_info':
      return P2pAdvertiserInfoResponse.fromJson(responseMap);
    case 'p2p_advertiser_update':
      return P2pAdvertiserUpdateResponse.fromJson(responseMap);
    case 'p2p_chat_create':
      return P2pChatCreateResponse.fromJson(responseMap);
    case 'p2p_order_cancel':
      return P2pOrderCancelResponse.fromJson(responseMap);
    case 'p2p_order_confirm':
      return P2pOrderConfirmResponse.fromJson(responseMap);
    case 'p2p_order_create':
      return P2pOrderCreateResponse.fromJson(responseMap);
    case 'p2p_order_info':
      return P2pOrderInfoResponse.fromJson(responseMap);
    case 'p2p_order_list':
      return P2pOrderListResponse.fromJson(responseMap);
    case 'paymentagent_list':
      return PaymentagentListResponse.fromJson(responseMap);
    case 'paymentagent_transfer':
      return PaymentagentTransferResponse.fromJson(responseMap);
    case 'paymentagent_withdraw':
      return PaymentagentWithdrawResponse.fromJson(responseMap);
    case 'payout_currencies':
      return PayoutCurrenciesResponse.fromJson(responseMap);
    case 'ping':
      return PingResponse.fromJson(responseMap);
    case 'portfolio':
      return PortfolioResponse.fromJson(responseMap);
    case 'profit_table':
      return ProfitTableResponse.fromJson(responseMap);
    case 'proposal_array':
      return ProposalArrayResponse.fromJson(responseMap);
    case 'proposal_open_contract':
      return ProposalOpenContractResponse.fromJson(responseMap);
    case 'proposal':
      return ProposalResponse.fromJson(responseMap);
    case 'reality_check':
      return RealityCheckResponse.fromJson(responseMap);
    case 'request_report':
      return RequestReportResponse.fromJson(responseMap);
    case 'reset_password':
      return ResetPasswordResponse.fromJson(responseMap);
    case 'residence_list':
      return ResidenceListResponse.fromJson(responseMap);
    case 'revoke_oauth_app':
      return RevokeOauthAppResponse.fromJson(responseMap);
    case 'sell_contract_for_multiple_accounts':
      return SellContractForMultipleAccountsResponse.fromJson(responseMap);
    case 'sell_expired':
      return SellExpiredResponse.fromJson(responseMap);
    case 'sell':
      return SellResponse.fromJson(responseMap);
    case 'service_token':
      return ServiceTokenResponse.fromJson(responseMap);
    case 'set_account_currency':
      return SetAccountCurrencyResponse.fromJson(responseMap);
    case 'set_financial_assessment':
      return SetFinancialAssessmentResponse.fromJson(responseMap);
    case 'set_self_exclusion':
      return SetSelfExclusionResponse.fromJson(responseMap);
    case 'set_settings':
      return SetSettingsResponse.fromJson(responseMap);
    case 'statement':
      return StatementResponse.fromJson(responseMap);
    case 'states_list':
      return StatesListResponse.fromJson(responseMap);
    case 'history':
      return TicksHistoryResponse.fromJson(responseMap);
    case 'tick':
      return TicksResponse.fromJson(responseMap);
    case 'time':
      return TimeResponse.fromJson(responseMap);
    case 'tnc_approval':
      return TncApprovalResponse.fromJson(responseMap);
    case 'topup_virtual':
      return TopupVirtualResponse.fromJson(responseMap);
    case 'trading_durations':
      return TradingDurationsResponse.fromJson(responseMap);
    case 'trading_times':
      return TradingTimesResponse.fromJson(responseMap);
    case 'transaction':
      return TransactionResponse.fromJson(responseMap);
    case 'transfer_between_accounts':
      return TransferBetweenAccountsResponse.fromJson(responseMap);
    case 'verify_email':
      return VerifyEmailResponse.fromJson(responseMap);
    case 'website_status':
      return WebsiteStatusResponse.fromJson(responseMap);

    default:
      return Response.fromJson(responseMap);
  }
}
