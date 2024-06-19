
use strict;
use warnings;
use Test::Most;
use Dir::Self;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use lib "$Bin";
use utf8;

use BOM::Test::Suite::DSL;

use LandingCompany::Registry;
use BOM::RPC::v3::Utility;
my $suite = start(
    title             => "accounts.t",
    test_app          => 'Binary::WebSocketAPI',
    suite_schema_path => __DIR__ . '/config/',
);

set_language 'EN';

my @currencies = LandingCompany::Registry::all_currencies();
my $currencies = sprintf("(%s)", join("|", @currencies));
my $length     = scalar @currencies;

# VIRTUAL ACCOUNT OPENING FOR (CR)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test1@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('test1@binary.com'), 'test1@binary.com', 'id';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
    $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'test1@binary.com';
fail_test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('test1@binary.com'), 'test1@binary.com', 'id';
# READ SCOPE CALLS (VRTC)
test_sendrecv_params 'balance/test_send.json', 'balance/test_receive.json', '10000', 'USD', $suite->get_stashed('authorize/authorize/loginid');
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json', 'USD', 1;
test_sendrecv 'login_history/test_send.json', 'login_history/test_receive.json';
test_sendrecv_params 'get_settings/test_send.json', 'get_settings/test_receive_vrtc.json', 'Indonesia', 'id';
test_sendrecv 'get_account_status/test_send.json', 'get_account_status/test_receive.json';
test_sendrecv 'kyc_auth_status/test_send.json',    'kyc_auth_status/test_receive.json';

# TRADE SCOPE CALLS (VRTC)
test_sendrecv 'topup_virtual/test_send.json', 'topup_virtual/test_receive.json';
test_sendrecv 'balance/test_send_subscribe.json', 'balance/test_receive.json',
    template_values => ['10000', 'USD', $suite->get_stashed('authorize/authorize/loginid')],
    start_stream_id => 1;
test_sendrecv 'proposal/test_send_buy.json', 'proposal/test_receive_buy.json';
test_sendrecv_params 'buy/test_send.json', 'buy/test_receive.json', $suite->get_stashed('proposal/proposal/id'), 9948.81;
test_last_stream_params 1, 'balance/test_receive_subscribe.json', 9948.81, 'USD', $suite->get_stashed('authorize/authorize/loginid');
test_sendrecv_params 'buy/test_send_with_params.json', 'buy/test_receive_with_params.json', 'payout', '5.12', '10';
test_sendrecv_params 'buy/test_send_with_params.json', 'buy/test_receive_with_params.json', 'stake',  '10',   '19.55';
test_sendrecv 'proposal/test_send_buy.json', 'proposal/test_receive_buy.json';
test_sendrecv_params 'buy_contract_for_multiple_accounts/test_send_invalid_token.json',
    'buy_contract_for_multiple_accounts/test_receive_invalid_token.json',
    $suite->get_stashed('proposal/proposal/id'), $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'dummy1234';

# Buy Lookbacks
test_sendrecv_params 'buy/test_send_lookback_with_params.json', 'buy/test_receive_lookback_with_params.json', 'unit', '154.86', '0';

# Buy Multiplier
test_sendrecv_params 'buy/test_send_multiplier_with_params.json', 'buy/test_receive_multiplier_with_params.json', '100', '0';

# ADMIN SCOPE CALLS (GENERAL)
test_sendrecv_params 'api_token/test_send_create.json', 'api_token/test_receive_create.json', 'test';
my $token = $suite->get_stashed('api_token/api_token/tokens/0/token');
test_sendrecv_params 'api_token/test_send_delete.json', 'api_token/test_receive_delete.json', $token;
test_sendrecv_params 'app_register/test_send.json',     'app_register/test_receive.json';
test_sendrecv_params 'app_get/test_send.json',          'app_get/test_receive.json',    $suite->get_stashed('app_register/app_register/app_id');
test_sendrecv_params 'app_update/test_send.json',       'app_update/test_receive.json', $suite->get_stashed('app_register/app_register/app_id');
fail_test_sendrecv_params 'app_list/test_send.json', 'app_list/test_receive_to_fail.json', $suite->get_stashed('app_register/app_register/app_id');
test_sendrecv_params 'app_delete/test_send.json', 'app_delete/test_receive.json', $suite->get_stashed('app_register/app_register/app_id'), '1';
test_sendrecv_params 'app_list/test_send.json',   'app_list/test_receive.json',   $suite->get_stashed('app_register/app_register/app_id');
test_sendrecv_params 'oauth_apps/test_send.json', 'oauth_apps/test_receive.json';
test_sendrecv 'get_limits/test_send.json', 'get_limits/test_receive_vrtc.json';

# TESTS TO RETURN ERROR (VRTC)
test_sendrecv 'set_settings/test_send.json',             'set_settings/test_receive_error.json';
test_sendrecv 'get_financial_assessment/test_send.json', 'get_financial_assessment/test_receive_vrt.json';

# TESTS TO RETURN ERROR (GENERAL)
test_sendrecv_params 'api_token/test_send_create.json', 'api_token/test_receive_create.json',       'test_123';
test_sendrecv_params 'api_token/test_send_create.json', 'api_token/test_receive_create_error.json', 'invalid-token-name';
# Create api token with the same display name
test_sendrecv_params 'api_token/test_send_create.json', 'api_token/test_receive_create.json', 'test_123';
test_sendrecv_params 'app_delete/test_send.json',       'app_delete/test_receive.json', $suite->get_stashed('app_register/app_register/app_id'), '1';
test_sendrecv_params 'app_update/test_send.json',       'app_update/test_receive_error.json', $suite->get_stashed('app_register/app_register/app_id');
test_sendrecv_params 'app_get/test_send.json',          'app_get/test_receive_error.json',    $suite->get_stashed('app_register/app_register/app_id');
test_sendrecv 'app_register/test_send.json', 'app_register/test_receive.json';
test_sendrecv 'app_register/test_send.json', 'app_register/test_receive_error.json';
fail_test_sendrecv 'login_history/test_send.json', 'login_history/test_receive_to_fail.json';

# REAL ACCOUNT OPENING (CR)
fail_test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_cr.json', 'Peter', 'zq', '+61234567000';
test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_cr.json', 'Peter', 'id', '+61234567001';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_cr.json',
    $suite->get_stashed('new_account_real/new_account_real/oauth_token'), 'test1@binary.com', 'Peter';
test_sendrecv_params 'balance/test_send.json', 'balance/test_receive.json', '0', '', $suite->get_stashed('authorize/authorize/loginid');
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json', $currencies, $length;

test_sendrecv 'set_financial_assessment/test_send.json', 'set_financial_assessment/test_receive.json';
test_sendrecv_params 'get_financial_assessment/test_send.json', 'get_financial_assessment/test_receive.json',
    $suite->get_stashed('set_financial_assessment/set_financial_assessment/total_score'),
    $suite->get_stashed('set_financial_assessment/set_financial_assessment/cfd_score'),
    $suite->get_stashed('set_financial_assessment/set_financial_assessment/trading_score'),
    $suite->get_stashed('set_financial_assessment/set_financial_assessment/financial_information_score');

# READ SCOPE CALLS (CR) BEFORE CHANGE
test_sendrecv 'get_limits/test_send.json',   'get_limits/test_receive_cr.json';
test_sendrecv 'get_settings/test_send.json', 'get_settings/test_receive_cr_before.json';
# ADMIN SCOPE CALLS (CR)
test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json',       'USD';
test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive_error.json', 'XXX';
test_sendrecv_params 'payout_currencies/test_send.json',    'payout_currencies/test_receive_vrt.json',      'USD', 1;
test_sendrecv_params 'balance/test_send.json', 'balance/test_receive.json', '0', 'USD', $suite->get_stashed('authorize/authorize/loginid');
test_sendrecv 'set_self_exclusion/test_send.json',            'set_self_exclusion/test_receive.json';
test_sendrecv 'set_settings/test_send.json',                  'set_settings/test_receive.json';
test_sendrecv 'set_settings/test_send_invalid_postcode.json', 'set_settings/test_receive_error_postcode.json';

# READ SCOPE CALLS (CR) AFTER CHANGE
test_sendrecv 'get_settings/test_send.json',       'get_settings/test_receive_cr_after.json';
test_sendrecv 'get_self_exclusion/test_send.json', 'get_self_exclusion/test_receive.json';

# READ SCOPE TESTS TO FAIL
fail_test_sendrecv 'get_settings/test_send.json',       'get_settings/test_receive_cr_before.json';
fail_test_sendrecv 'get_self_exclusion/test_send.json', 'get_self_exclusion/test_receive_to_fail.json';

# TRADE SCOPE CALLS (CR)
test_sendrecv 'topup_virtual/test_send.json', 'topup_virtual/test_receive_error.json';

# PAYMENT SCOPE CALLS (CR)
test_sendrecv_params 'cashier/test_send_deposit.json',  'cashier/test_receive_error.json';
test_sendrecv_params 'verify_email/test_send.json',     'verify_email/test_receive.json',  'test1@binary.com', 'payment_withdraw';
test_sendrecv_params 'cashier/test_send_withdraw.json', 'cashier/test_receive_error.json', $suite->get_token('test1@binary.com');

test_sendrecv_params 'change_password/test_send.json', 'change_password/test_receive_error.json', 'Abcd123!', 'Abcd123!';
test_sendrecv_params 'change_password/test_send.json', 'change_password/test_receive_error.json', 'Abcd123!', 'Test1@binary.com';
test_sendrecv_params 'change_password/test_send.json', 'change_password/test_receive_error.json', '1231asda', 'Abcd33!@';
test_sendrecv_params 'change_password/test_send.json', 'change_password/test_receive.json',       'Abcd123!', 'Abcd33!@#!@#';

# as we created token for payment_withdraw which returned with error so token was not expired
# so reset password is not allowed with that token
fail_test_sendrecv_params 'reset_password/test_send_real.json', 'reset_password/test_receive.json', $suite->get_token('test1@binary.com'), 'Abcd123!';
test_sendrecv_params 'verify_email/test_send.json',        'verify_email/test_receive.json',   'test1@binary.com', 'reset_password';
test_sendrecv_params 'reset_password/test_send_real.json', 'reset_password/test_receive.json', $suite->get_token('test1@binary.com'), 'Abcd123!';
test_sendrecv_params 'verify_email/test_send.json',        'verify_email/test_receive.json',   'test1@binary.com', 'reset_password';
fail_test_sendrecv_params 'reset_password/test_send_real.json', 'reset_password/test_receive.json', $suite->get_token('test1@binary.com'),
    'Test1@binary.com';
# same token cannot be used twice
fail_test_sendrecv_params 'reset_password/test_send_real.json', 'reset_password/test_receive.json', $suite->get_token('test1@binary.com'), 'Abcd123!';

# VIRTUAL ACCOUNT OPENING (VRTC)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test2@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('test2@binary.com'), 'test2@binary.com', 'au';
test_sendrecv_params 'verify_email/test_send.json',       'verify_email/test_receive.json',   'test2@binary.com',                    'reset_password';
test_sendrecv_params 'reset_password/test_send_vrt.json', 'reset_password/test_receive.json', $suite->get_token('test2@binary.com'), 'Abcd123!';

# TESTS TO RETURN ERROR (LOGGED OUT)
test_sendrecv 'logout/test_send.json', 'logout/test_receive.json';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_error.json',
    $suite->get_stashed('new_account_real/new_account_real/oauth_token');
test_sendrecv 'balance/test_send.json',            'balance/test_receive_error.json';
test_sendrecv 'get_account_status/test_send.json', 'get_account_status/test_receive_error.json';
test_sendrecv 'kyc_auth_status/test_send.json',    'kyc_auth_status/test_receive_error.json';

# VIRTUAL ACCOUNT OPENING FOR (MF)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'error@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('error@binary.com'), 'error@binary.com', 'dk';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
    $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'error@binary.com';

test_sendrecv 'logout/test_send.json', 'logout/test_receive.json';

# FINANCIAL ACCOUNT OPENING error (MF)
test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive_error.json', '0', 'Jack', 'dk', 81,
    '+61234567006',
    '1112223334';

# VIRTUAL another ACCOUNT OPENING FOR (MF)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'mf@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('mf@binary.com'), 'mf@binary.com', 'dk';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
    $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'mf@binary.com';

# CONFIRM EMAIL
test_sendrecv_params 'verify_email/test_send.json',  'verify_email/test_receive.json',  'test@binary.com',                    'account_verification';
test_sendrecv_params 'confirm_email/test_send.json', 'confirm_email/test_receive.json', $suite->get_token('test@binary.com'), '1';

# FINANCIAL ACCOUNT OPENING (MF)
test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive.json', '1', 'Jack', 'dk', 81, '+61234567008',
    '1112223334';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_mf.json',
    $suite->get_stashed('new_account_maltainvest/new_account_maltainvest/oauth_token'), 'mf@binary.com', 'Jack';
test_sendrecv_params 'balance/test_send.json', 'balance/test_receive.json', '0', '', $suite->get_stashed('authorize/authorize/loginid');
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json', '(USD|EUR|GBP)', 3;
fail_test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json', '(USD|EUR|JPY)', 3;

# ADMIN SCOPE CALLS (MF)
test_sendrecv 'set_financial_assessment/test_send_mf.json', 'set_financial_assessment/test_receive.json';
test_sendrecv_params 'get_financial_assessment/test_send.json', 'get_financial_assessment/test_receive_mf.json',
    $suite->get_stashed('set_financial_assessment/set_financial_assessment/total_score'),
    $suite->get_stashed('set_financial_assessment/set_financial_assessment/cfd_score'),
    $suite->get_stashed('set_financial_assessment/set_financial_assessment/trading_score'),
    $suite->get_stashed('set_financial_assessment/set_financial_assessment/financial_information_score');

# TWO Factor Authentication (Admin Scope)
test_sendrecv_params 'account_security/test_send_status.json', 'account_security/test_receive_status.json';

# Payment Methods
test_sendrecv 'payment_methods/test_send_payment_methods.json',              'payment_methods/test_receive_empty.json';
test_sendrecv 'payment_methods/test_send_payment_methods_with_country.json', 'payment_methods/test_receive_empty.json';

# BINDING WALLET <-> TRADING ACCOUNTS (Admin Scope)
test_sendrecv_params 'link_wallet/test_send.json', 'link_wallet/test_receive.json';

#  appstore webservices
test_sendrecv_params 'get_account_types/test_send.json',  'get_account_types/test_receive.json',  $suite->get_stashed('authorize/authorize/loginid');
test_sendrecv_params 'available_accounts/test_send.json', 'available_accounts/test_receive.json', $suite->get_stashed('authorize/authorize/loginid');

# account_list
test_sendrecv 'account_list/test_send.json', 'account_list/test_receive.json';

fail_test_sendrecv 'logout/test_send_to_fail.json', 'logout/test_receive.json';
test_sendrecv 'logout/test_send.json', 'logout/test_receive.json';

# verify_email for cellxpert

test_sendrecv 'verify_email_cellxpert/test_send_to_fail.json', 'verify_email_cellxpert/test_receive_fail.json';
fail_test_sendrecv 'verify_email_cellxpert/test_send.json', 'verify_email_cellxpert/test_receive_fail.json';

# VIRTUAL ACCOUNT OPENING FOR (CR with FATCA declaration)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test3@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('test3@binary.com'), 'test3@binary.com', 'id';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
    $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'test3@binary.com';

# REAL ACCOUNT OPENING (CR with FATCA declaration)
fail_test_sendrecv_params 'new_account_real/test_send_fatca.json', 'new_account_real/test_receive_cr.json', 'Peter', 'id', '+61234567002', 'abcd';
test_sendrecv_params 'new_account_real/test_send_fatca.json', 'new_account_real/test_receive_cr.json', 'Peter', 'id', '+61234567002', 1;
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_cr.json',
    $suite->get_stashed('new_account_real/new_account_real/oauth_token'), 'test3@binary.com', 'Peter';
test_sendrecv 'get_settings/test_send.json', 'get_settings/test_receive_cr_before.json';

finish;
