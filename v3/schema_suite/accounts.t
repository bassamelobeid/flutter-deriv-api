use strict;
use warnings;
use Test::Most;
use Dir::Self;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use lib "$Bin";

use BOM::Test::Suite::DSL;

my $suite = start(
    title             => "accounts.t",
    test_app          => 'Binary::WebSocketAPI',
    suite_schema_path => __DIR__ . '/config/',
);

set_language 'EN';

# VIRTUAL ACCOUNT OPENING FOR (CR)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json',
    'test@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('test@binary.com'), 'test@binary.com', 'id';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
    $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'test@binary.com';
fail_test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('test@binary.com'), 'test@binary.com', 'id';

# READ SCOPE CALLS (VRTC)
test_sendrecv_params 'balance/test_send.json', 'balance/test_receive.json',
    '10000\\\\.00', 'USD', $suite->get_stashed('authorize/authorize/loginid');
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json',
    'USD', 1;
test_sendrecv 'login_history/test_send.json', 'login_history/test_receive.json';
test_sendrecv_params 'get_settings/test_send.json', 'get_settings/test_receive_vrtc.json',
    'Indonesia', 'id';
test_sendrecv 'get_account_status/test_send.json', 'get_account_status/test_receive.json';

# TRADE SCOPE CALLS (VRTC)
test_sendrecv 'topup_virtual/test_send.json', 'topup_virtual/test_receive_error.json';
test_sendrecv 'balance/test_send_subscribe.json', 'balance/test_receive.json',
    template_values => [ '10000\\\\.00', 'USD', $suite->get_stashed('authorize/authorize/loginid') ],
    start_stream_id => 1;
test_sendrecv 'proposal/test_send_buy.json', 'proposal/test_receive_buy.json';
test_sendrecv_params 'buy/test_send.json', 'buy/test_receive.json',
    $suite->get_stashed('proposal/proposal/id'), '99\\\\d{2}\\\\.\\\\d{2}';
test_last_stream_params 1, 'balance/test_receive.json',
    '99\\\\d{2}\\\\.\\\\d{2}', 'USD', $suite->get_stashed('authorize/authorize/loginid');
test_sendrecv_params 'buy/test_send_with_params.json', 'buy/test_receive_with_params.json',
    'payout', '5.15', '10';
test_sendrecv_params 'buy/test_send_with_params.json', 'buy/test_receive_with_params.json',
    'stake', '10', '19.43';
test_sendrecv_params 'buy_contract_for_multiple_accounts/test_send_invalid_token.json', 'buy_contract_for_multiple_accounts/test_receive_invalid_token.json',
    $suite->get_stashed('proposal/id'), $suite->get_stashed('new_account_real/new_account_real/oauth_token'), 'dummy1234';

# ADMIN SCOPE CALLS (GENERAL)
test_sendrecv_params 'api_token/test_send_create.json', 'api_token/test_receive_create.json',
    'test';
test_sendrecv_params 'api_token/test_send.json', 'api_token/test_receive.json',
    $suite->get_stashed('api_token/api_token/tokens/0/token');
test_sendrecv_params 'api_token/test_send_delete.json', 'api_token/test_receive_delete.json',
    $suite->get_stashed('api_token/api_token/tokens/0/token');
test_sendrecv_params 'app_register/test_send.json', 'app_register/test_receive.json';
test_sendrecv_params 'app_get/test_send.json', 'app_get/test_receive.json',
    $suite->get_stashed('app_register/app_register/app_id');
test_sendrecv_params 'app_update/test_send.json', 'app_update/test_receive.json',
    $suite->get_stashed('app_register/app_register/app_id');
fail_test_sendrecv_params 'app_list/test_send.json', 'app_list/test_receive_to_fail.json',
    $suite->get_stashed('app_register/app_register/app_id');
test_sendrecv_params 'app_delete/test_send.json', 'app_delete/test_receive.json',
    $suite->get_stashed('app_register/app_register/app_id'), '1';
test_sendrecv_params 'app_list/test_send.json', 'app_list/test_receive.json',
    $suite->get_stashed('app_register/app_register/app_id');
test_sendrecv_params 'oauth_apps/test_send.json', 'oauth_apps/test_receive.json';

# TESTS TO RETURN ERROR (VRTC)
test_sendrecv 'get_limits/test_send.json', 'get_limits/test_receive_error.json';
test_sendrecv 'set_settings/test_send.json', 'set_settings/test_receive_error.json';
test_sendrecv 'get_financial_assessment/test_send.json', 'get_financial_assessment/test_receive_vrt.json';

# TESTS TO RETURN ERROR (GENERAL)
test_sendrecv_params 'api_token/test_send_create.json', 'api_token/test_receive_create.json',
    'test';
test_sendrecv_params 'api_token/test_send_create.json', 'api_token/test_receive_error.json',
    'test';
test_sendrecv_params 'app_delete/test_send.json', 'app_delete/test_receive.json',
    $suite->get_stashed('app_register/app_register/app_id'), '0';
test_sendrecv_params 'app_update/test_send.json', 'app_update/test_receive_error.json',
    $suite->get_stashed('app_register/app_register/app_id');
test_sendrecv_params 'app_get/test_send.json', 'app_get/test_receive_error.json',
    $suite->get_stashed('app_register/app_register/app_id');
test_sendrecv 'app_register/test_send.json', 'app_register/test_receive.json';
test_sendrecv 'app_register/test_send.json', 'app_register/test_receive_error.json';
fail_test_sendrecv 'login_history/test_send.json', 'login_history/test_receive_to_fail.json';

# REAL ACCOUNT OPENING (CR)
fail_test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_cr.json',
    'Peter', 'zq';
test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_cr.json',
    'Peter', 'id';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_cr.json',
    $suite->get_stashed('new_account_real/new_account_real/oauth_token'), 'test@binary.com', 'Peter';
test_sendrecv_params 'balance/test_send.json', 'balance/test_receive.json',
    '0\\\\.00', '', $suite->get_stashed('authorize/authorize/loginid');
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json',
    '(USD|EUR|GBP|AUD|BTC|LTC)', 6;

# READ SCOPE CALLS (CR) BEFORE CHANGE
test_sendrecv 'get_limits/test_send.json', 'get_limits/test_receive_cr.json';
test_sendrecv 'get_settings/test_send.json', 'get_settings/test_receive_cr_before.json';

# ADMIN SCOPE CALLS (CR)
test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json',
    'USD';
test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive_error.json',
    'GBP';
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json',
    'USD', 1;
test_sendrecv_params 'balance/test_send.json', 'balance/test_receive.json',
    '0\\\\.00', 'USD', $suite->get_stashed('authorize/authorize/loginid');
test_sendrecv 'set_self_exclusion/test_send.json', 'set_self_exclusion/test_receive.json';
test_sendrecv 'set_settings/test_send.json', 'set_settings/test_receive.json';

# READ SCOPE CALLS (CR) AFTER CHANGE
test_sendrecv 'get_settings/test_send.json', 'get_settings/test_receive_cr_after.json';
test_sendrecv 'get_self_exclusion/test_send.json', 'get_self_exclusion/test_receive.json';

# READ SCOPE TESTS TO FAIL
fail_test_sendrecv 'get_settings/test_send.json', 'get_settings/test_receive_cr_before.json';
fail_test_sendrecv 'get_self_exclusion/test_send.json', 'get_self_exclusion/test_receive_to_fail.json';

# TRADE SCOPE CALLS (CR)
test_sendrecv 'topup_virtual/test_send.json', 'topup_virtual/test_receive_error.json';

# PAYMENT SCOPE CALLS (CR)
test_sendrecv_params 'cashier_password/test_send.json', 'cashier_password/test_receive.json',
    '0';
test_sendrecv_params 'cashier_password/test_send_lock.json', 'cashier_password/test_receive.json',
    '1', 'Abc1234';
test_sendrecv_params 'cashier/test_send_deposit.json', 'cashier/test_receive_error.json';
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json',
    'test@binary.com', 'payment_withdraw';
test_sendrecv_params 'cashier/test_send_withdraw.json', 'cashier/test_receive_error.json',
    $suite->get_token('test@binary.com');
test_sendrecv_params 'cashier_password/test_send_lock.json','cashier_password/test_receive_error.json',
    '', 'Abc1234';
test_sendrecv_params 'cashier_password/test_send.json', 'cashier_password/test_receive.json',
    '1';
test_sendrecv_params 'cashier_password/test_send_unlock.json', 'cashier_password/test_receive.json',
    '0', 'Abc1234';
test_sendrecv_params 'cashier_password/test_send_unlock.json', 'cashier_password/test_receive_error.json',
    '', 'Abc1234';
test_sendrecv_params 'cashier_password/test_send_lock.json', 'cashier_password/test_receive_password_error.json',
    '', 'abc1234';
test_sendrecv_params 'cashier_password/test_send_lock.json', 'cashier_password/test_receive_error.json',
    '', 'Abc123';

test_sendrecv_params 'change_password/test_send.json', 'change_password/test_receive_error.json',
    'Abc123', 'Abc123';
test_sendrecv_params 'change_password/test_send.json', 'change_password/test_receive_error.json',
    'Abc123', 'abc123';
test_sendrecv_params 'change_password/test_send.json', 'change_password/test_receive_error.json',
    'abc123', 'Abcd123';
test_sendrecv_params 'change_password/test_send.json', 'change_password/test_receive.json',
    'Abc123', 'Abcd1234';

# as we created token for payment_withdraw which returned with error so token was not expired
# so reset password is not allowed with that token
fail_test_sendrecv_params 'reset_password/test_send_real.json', 'reset_password/test_receive.json',
    $suite->get_token('test@binary.com'), 'Abc123';
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json',
    'test@binary.com', 'reset_password';
test_sendrecv_params 'reset_password/test_send_real.json', 'reset_password/test_receive.json',
    $suite->get_token('test@binary.com'), 'Abc123';
# same token cannot be used twice
fail_test_sendrecv_params 'reset_password/test_send_real.json', 'reset_password/test_receive.json',
    $suite->get_token('test@binary.com'), 'Abc123';

# TESTS TO RETURN ERROR (LOGGED OUT)
test_sendrecv 'logout/test_send.json', 'logout/test_receive.json';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_error.json',
    $suite->get_stashed('new_account_real/new_account_real/oauth_token');
test_sendrecv 'balance/test_send.json', 'balance/test_receive_error.json';
test_sendrecv 'get_account_status/test_send.json', 'get_account_status/test_receive_error.json';

# VIRTUAL ACCOUNT OPENING FOR (MLT)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json',
    'test-mlt@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('test-mlt@binary.com'), 'test-mlt@binary.com', 'dk';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
    $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'test-mlt@binary.com';

# REAL ACCOUNT OPENING (MLT)
test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_mlt.json',
    'Jack', 'dk';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_mlt.json',
    $suite->get_stashed('new_account_real/new_account_real/oauth_token'), 'test-mlt@binary.com', 'Jack';
test_sendrecv_params 'balance/test_send.json', 'balance/test_receive.json',
    '0\\\\.00', '', $suite->get_stashed('authorize/authorize/loginid');
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json',
    '(USD|EUR|GBP)', 3;
fail_test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json',
    '(USD|EUR|JPY)', 3;

# SUB ACCOUNT OPENING
$suite->set_allow_omnibus('new_account_real/new_account_real/client_id');
test_sendrecv 'new_sub_account/test_send.json', 'new_sub_account/test_receive.json';
test_sendrecv 'new_sub_account/test_send_details.json', 'new_sub_account/test_receive.json';

# READ SCOPE CALLS (MLT) BEFORE CHANGE
test_sendrecv_params 'reality_check/test_send.json', 'reality_check/test_receive.json',
    '';

# PAYMENT SCOPE CALLS (MLT)
test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json',
    'EUR';
test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive_error.json',
    'GBP';
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json',
    'EUR', 1;
fail_test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json',
    'USD', 1;

# READ SCOPE CALLS (MLT) AFTER CHANGE
fail_test_sendrecv_params 'reality_check/test_send.json', 'reality_check/test_receive.json',
    'GBP';
test_sendrecv_params 'reality_check/test_send.json', 'reality_check/test_receive.json',
    'EUR';

# FINANCIAL ACCOUNT OPENING (MF)
test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive_error.json',
    '0', 'Jack', 'dk';
test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive.json',
    '1', 'Jack', 'dk';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_mf.json',
    $suite->get_stashed('new_account_maltainvest/new_account_maltainvest/oauth_token'), 'test-mlt@binary.com', 'Jack';
test_sendrecv_params 'balance/test_send.json', 'balance/test_receive.json',
    '0\\\\.00', '', $suite->get_stashed('authorize/authorize/loginid');
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json',
    '(USD|EUR|GBP)', 3;
fail_test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json',
    '(USD|EUR|JPY)', 3;

# ADMIN SCOPE CALLS (MF)
test_sendrecv 'set_financial_assessment/test_send.json', 'set_financial_assessment/test_receive.json';
test_sendrecv_params 'get_financial_assessment/test_send.json', 'get_financial_assessment/test_receive.json',
    $suite->get_stashed('set_financial_assessment/set_financial_assessment/score');

fail_test_sendrecv 'logout/test_send_to_fail.json', 'logout/test_receive.json';
test_sendrecv 'logout/test_send.json', 'logout/test_receive.json';

# have to restart the websocket connection because rate limit of verify_email call is reached
reset_app;

# VIRTUAL ACCOUNT OPENING (VRTJ TO FAIL KNOWLEDGE TEST)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json',
    'test-jp@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive_vrtj.json',
    $suite->get_token('test-jp@binary.com'), 'test-jp@binary.com', 'jp';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtj.json',
    $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'test-jp@binary.com';

# READ SCOPE CALLS (VRTJ)
test_sendrecv_params 'balance/test_send.json', 'balance/test_receive.json',
    '1000000\\\\.00', 'JPY', $suite->get_stashed('authorize/authorize/loginid');
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json',
    'JPY', 1;
fail_test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json',
    'USD', 1;
test_sendrecv 'get_settings/test_send.json', 'get_settings/test_receive_vrtj_before.json';
test_sendrecv 'get_account_status/test_send.json', 'get_account_status/test_receive.json';

# TESTS TO RETURN ERROR (VRTJ)
test_sendrecv 'get_limits/test_send.json', 'get_limits/test_receive_error.json';
test_sendrecv 'get_financial_assessment/test_send.json', 'get_financial_assessment/test_receive_vrt.json';

# REAL ACCOUNT OPENING (JP)
test_sendrecv_params 'new_account_japan/test_send.json', 'new_account_japan/test_receive.json',
    'Susan';
test_sendrecv_params 'get_settings/test_send.json', 'get_settings/test_receive_vrtj_after.json',
    'jp_knowledge_test_pending', 'test-jp@binary.com';
test_sendrecv_params 'jp_knowledge_test/test_send.json', 'jp_knowledge_test/test_receive.json',
    '8', 'fail';
fail_test_sendrecv_params 'jp_knowledge_test/test_send.json', 'jp_knowledge_test/test_receive_error.json',
    '230', 'succeed';
test_sendrecv 'get_settings/test_send.json', 'get_settings/test_receive_vrtj_fail.json';

# VIRTUAL ACCOUNT OPENING (VRTJ TO PASS KNOWLEDGE TEST)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json',
    'test-jp2@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive_vrtj.json',
    $suite->get_token('test-jp2@binary.com'), 'test-jp2@binary.com', 'jp';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtj.json',
    $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'test-jp2@binary.com';

# REAL ACCOUNT OPENING (JP)
test_sendrecv_params 'new_account_japan/test_send.json', 'new_account_japan/test_receive_error.json',
    'Susan';
test_sendrecv_params 'new_account_japan/test_send.json', 'new_account_japan/test_receive.json',
    'Julie';
test_sendrecv_params 'jp_knowledge_test/test_send.json', 'jp_knowledge_test/test_receive.json',
    '12', 'pass';
test_sendrecv_params 'get_settings/test_send.json', 'get_settings/test_receive_vrtj_after.json',
    'jp_activation_pending', 'test-jp2@binary.com';

# VIRTUAL ACCOUNT OPENING FOR (MX)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json',
    'test-mx@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('test-mx@binary.com'), 'test-mx@binary.com', 'gb';

# REAL ACCOUNT OPENING (MX)
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
    $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'test-mx@binary.com';
test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_mx.json',
    'John', 'gb';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_mx.json',
    $suite->get_stashed('new_account_real/new_account_real/oauth_token'), 'test-mx@binary.com', 'John';
test_sendrecv_params 'balance/test_send.json', 'balance/test_receive.json',
    '0\\\\.00', '', $suite->get_stashed('authorize/authorize/loginid');
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json',
    '(USD|GBP)', 2;
fail_test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json',
    '(EUR|GBP)', 2;

# PAYMENT SCOPE CALLS (MX)
test_sendrecv 'cashier/test_send_deposit.json', 'cashier/test_receive_currency_error.json';
test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json',
    'GBP';
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json',
    'GBP', 1;
fail_test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json',
    'EUR', 1;
test_sendrecv 'cashier/test_send_deposit.json', 'cashier/test_receive_ukgc_error.json';
test_sendrecv 'tnc_approval/test_send_ukgc.json', 'tnc_approval/test_receive.json';
$suite->change_status($suite->get_stashed('authorize/authorize/loginid'), 'set', 'age_verification');
$suite->change_status($suite->get_stashed('authorize/authorize/loginid'), 'set', 'ukrts_max_turnover_limit_not_set');
test_sendrecv 'cashier/test_send_deposit.json', 'cashier/test_receive_max_turnover.json';
# set_self_exclusion for max_30day_turnover should remove ukrts_max_turnover_limit_not_set status
test_sendrecv 'set_self_exclusion/test_send.json', 'set_self_exclusion/test_receive.json';
test_sendrecv_params 'balance/test_send.json', 'balance/test_receive.json',
    '0\\\\.00', 'GBP', $suite->get_stashed('authorize/authorize/loginid');

# VIRTUAL ACCOUNT OPENING (VRTC)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json',
    'test2@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('test2@binary.com'), 'test2@binary.com', 'au';
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json',
    'test2@binary.com', 'reset_password';
test_sendrecv_params 'reset_password/test_send_vrt.json', 'reset_password/test_receive.json',
    $suite->get_token('test2@binary.com'), 'Abc123';

finish;
