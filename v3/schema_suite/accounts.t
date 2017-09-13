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

while (defined(my $line = <DATA>)) {
    chomp $line;
    next if ($line =~ /^(#.*|)$/);
    $suite->exec_line($line, $.);
}

finish;

BEGIN { DATA->input_line_number(__LINE__ + 1) }    # ensure that $. reports physical line
__DATA__

# TRADE SCOPE CALLS (VRTC)
topup_virtual/test_send.json,topup_virtual/test_receive_error.json
{start_stream:1}balance/test_send_subscribe.json,balance/test_receive.json, '10000\\.00', 'USD', _get_stashed('authorize/authorize/loginid')
proposal/test_send_buy.json,proposal/test_receive_buy.json
buy/test_send.json,buy/test_receive.json,_get_stashed('proposal/proposal/id'), '99\\d{2}\\.\\d{2}'
{test_last_stream_message:1}balance/test_receive.json, '99\\d{2}\\.\\d{2}', 'USD', _get_stashed('authorize/authorize/loginid')
buy/test_send_with_params.json,buy/test_receive_with_params.json, 'payout', '5.15', '10'
buy/test_send_with_params.json,buy/test_receive_with_params.json, 'stake', '10', '19.43'
buy_contract_for_multiple_accounts/test_send_invalid_token.json,buy_contract_for_multiple_accounts/test_receive_invalid_token.json,_get_stashed('proposal/id'),_get_stashed('new_account_real/new_account_real/oauth_token'),'dummy1234'

# ADMIN SCOPE CALLS (GENERAL)
api_token/test_send_create.json,api_token/test_receive_create.json, 'test'
api_token/test_send.json,api_token/test_receive.json,_get_stashed('api_token/api_token/tokens/0/token')
api_token/test_send_delete.json,api_token/test_receive_delete.json,_get_stashed('api_token/api_token/tokens/0/token')
app_register/test_send.json,app_register/test_receive.json
app_get/test_send.json,app_get/test_receive.json,_get_stashed('app_register/app_register/app_id')
app_update/test_send.json,app_update/test_receive.json,_get_stashed('app_register/app_register/app_id')
!app_list/test_send.json,app_list/test_receive_to_fail.json,_get_stashed('app_register/app_register/app_id')
app_delete/test_send.json,app_delete/test_receive.json,_get_stashed('app_register/app_register/app_id'), '1'
app_list/test_send.json,app_list/test_receive.json,_get_stashed('app_register/app_register/app_id')
oauth_apps/test_send.json,oauth_apps/test_receive.json

# TESTS TO RETURN ERROR (VRTC)
get_limits/test_send.json,get_limits/test_receive_error.json
set_settings/test_send.json,set_settings/test_receive_error.json
get_financial_assessment/test_send.json,get_financial_assessment/test_receive_vrt.json

# TESTS TO RETURN ERROR (GENERAL)
api_token/test_send_create.json,api_token/test_receive_create.json, 'test'
api_token/test_send_create.json,api_token/test_receive_error.json, 'test'
app_delete/test_send.json,app_delete/test_receive.json,_get_stashed('app_register/app_register/app_id'), '0'
app_update/test_send.json,app_update/test_receive_error.json,_get_stashed('app_register/app_register/app_id')
app_get/test_send.json,app_get/test_receive_error.json,_get_stashed('app_register/app_register/app_id')
app_register/test_send.json,app_register/test_receive.json
app_register/test_send.json,app_register/test_receive_error.json
!login_history/test_send.json,login_history/test_receive_to_fail.json

# REAL ACCOUNT OPENING (CR)
!new_account_real/test_send.json,new_account_real/test_receive_cr.json, 'Peter', 'zq'
new_account_real/test_send.json,new_account_real/test_receive_cr.json, 'Peter', 'id'
authorize/test_send.json,authorize/test_receive_cr.json,_get_stashed('new_account_real/new_account_real/oauth_token'),'test@binary.com','Peter'
balance/test_send.json,balance/test_receive.json, '0\\.00', '', _get_stashed('authorize/authorize/loginid')
payout_currencies/test_send.json,payout_currencies/test_receive_vrt.json, '(USD|EUR|GBP|AUD|BTC|LTC)', 6

# READ SCOPE CALLS (CR) BEFORE CHANGE
get_limits/test_send.json,get_limits/test_receive_cr.json
get_settings/test_send.json,get_settings/test_receive_cr_before.json

# ADMIN SCOPE CALLS (CR)
set_account_currency/test_send.json,set_account_currency/test_receive.json, 'USD'
set_account_currency/test_send.json,set_account_currency/test_receive_error.json, 'GBP'
payout_currencies/test_send.json,payout_currencies/test_receive_vrt.json, 'USD', 1
balance/test_send.json,balance/test_receive.json, '0\\.00', 'USD', _get_stashed('authorize/authorize/loginid')
set_self_exclusion/test_send.json,set_self_exclusion/test_receive.json
set_settings/test_send.json,set_settings/test_receive.json

# READ SCOPE CALLS (CR) AFTER CHANGE
get_settings/test_send.json,get_settings/test_receive_cr_after.json
get_self_exclusion/test_send.json,get_self_exclusion/test_receive.json

# READ SCOPE TESTS TO FAIL
!get_settings/test_send.json,get_settings/test_receive_cr_before.json
!get_self_exclusion/test_send.json,get_self_exclusion/test_receive_to_fail.json

# TRADE SCOPE CALLS (CR)
topup_virtual/test_send.json,topup_virtual/test_receive_error.json

# PAYMENT SCOPE CALLS (CR)
cashier_password/test_send.json,cashier_password/test_receive.json, '0'
cashier_password/test_send_lock.json,cashier_password/test_receive.json, '1', 'Abc1234'
cashier/test_send_deposit.json,cashier/test_receive_error.json
verify_email/test_send.json,verify_email/test_receive.json, 'test@binary.com', 'payment_withdraw'
cashier/test_send_withdraw.json,cashier/test_receive_error.json,_get_token('test@binary.com')
cashier_password/test_send_lock.json,cashier_password/test_receive_error.json, '', 'Abc1234'
cashier_password/test_send.json,cashier_password/test_receive.json, '1'
cashier_password/test_send_unlock.json,cashier_password/test_receive.json, '0', 'Abc1234'
cashier_password/test_send_unlock.json,cashier_password/test_receive_error.json, '', 'Abc1234'
cashier_password/test_send_lock.json,cashier_password/test_receive_password_error.json, '', 'abc1234'
cashier_password/test_send_lock.json,cashier_password/test_receive_error.json, '', 'Abc123'

change_password/test_send.json,change_password/test_receive_error.json, 'Abc123', 'Abc123'
change_password/test_send.json,change_password/test_receive_error.json, 'Abc123', 'abc123'
change_password/test_send.json,change_password/test_receive_error.json, 'abc123', 'Abcd123'
change_password/test_send.json,change_password/test_receive.json, 'Abc123', 'Abcd1234'

# as we created token for payment_withdraw which returned with error so token was not expired
# so reset password is not allowed with that token
!reset_password/test_send_real.json,reset_password/test_receive.json,_get_token('test@binary.com'), 'Abc123'
verify_email/test_send.json,verify_email/test_receive.json, 'test@binary.com', 'reset_password'
reset_password/test_send_real.json,reset_password/test_receive.json,_get_token('test@binary.com'), 'Abc123'
# same token cannot be used twice
!reset_password/test_send_real.json,reset_password/test_receive.json,_get_token('test@binary.com'), 'Abc123'

# TESTS TO RETURN ERROR (LOGGED OUT)
logout/test_send.json,logout/test_receive.json
authorize/test_send.json,authorize/test_receive_error.json,_get_stashed('new_account_real/new_account_real/oauth_token')
balance/test_send.json,balance/test_receive_error.json
get_account_status/test_send.json,get_account_status/test_receive_error.json

# VIRTUAL ACCOUNT OPENING FOR (MLT)
verify_email/test_send.json,verify_email/test_receive.json, 'test-mlt@binary.com', 'account_opening'
new_account_virtual/test_send.json,new_account_virtual/test_receive.json,_get_token('test-mlt@binary.com'), 'test-mlt@binary.com', 'dk'
authorize/test_send.json,authorize/test_receive_vrtc.json,_get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'test-mlt@binary.com'

# REAL ACCOUNT OPENING (MLT)
new_account_real/test_send.json,new_account_real/test_receive_mlt.json, 'Jack', 'dk'
authorize/test_send.json,authorize/test_receive_mlt.json,_get_stashed('new_account_real/new_account_real/oauth_token'), 'test-mlt@binary.com', 'Jack'
balance/test_send.json,balance/test_receive.json, '0\\.00', '', _get_stashed('authorize/authorize/loginid')
payout_currencies/test_send.json,payout_currencies/test_receive_vrt.json, '(USD|EUR|GBP)', 3
!payout_currencies/test_send.json,payout_currencies/test_receive_vrt.json, '(USD|EUR|JPY)', 3

# SUB ACCOUNT OPENING
[% _set_allow_omnibus('new_account_real/new_account_real/client_id') %]new_sub_account/test_send.json,new_sub_account/test_receive.json
new_sub_account/test_send_details.json,new_sub_account/test_receive.json

# READ SCOPE CALLS (MLT) BEFORE CHANGE
reality_check/test_send.json,reality_check/test_receive.json, ''

# PAYMENT SCOPE CALLS (MLT)
set_account_currency/test_send.json,set_account_currency/test_receive.json, 'EUR'
set_account_currency/test_send.json,set_account_currency/test_receive_error.json, 'GBP'
payout_currencies/test_send.json,payout_currencies/test_receive_vrt.json, 'EUR', 1
!payout_currencies/test_send.json,payout_currencies/test_receive_vrt.json, 'USD', 1

# READ SCOPE CALLS (MLT) AFTER CHANGE
!reality_check/test_send.json,reality_check/test_receive.json, 'GBP'
reality_check/test_send.json,reality_check/test_receive.json, 'EUR'

# FINANCIAL ACCOUNT OPENING (MF)
new_account_maltainvest/test_send.json,new_account_maltainvest/test_receive_error.json, '0', 'Jack', 'dk'
new_account_maltainvest/test_send.json,new_account_maltainvest/test_receive.json, '1', 'Jack', 'dk'
authorize/test_send.json,authorize/test_receive_mf.json,_get_stashed('new_account_maltainvest/new_account_maltainvest/oauth_token'), 'test-mlt@binary.com', 'Jack'
balance/test_send.json,balance/test_receive.json, '0\\.00', '', _get_stashed('authorize/authorize/loginid')
payout_currencies/test_send.json,payout_currencies/test_receive_vrt.json, '(USD|EUR|GBP)', 3
!payout_currencies/test_send.json,payout_currencies/test_receive_vrt.json, '(USD|EUR|JPY)', 3

# ADMIN SCOPE CALLS (MF)
set_financial_assessment/test_send.json,set_financial_assessment/test_receive.json
get_financial_assessment/test_send.json,get_financial_assessment/test_receive.json,_get_stashed('set_financial_assessment/set_financial_assessment/score')

!logout/test_send_to_fail.json,logout/test_receive.json
logout/test_send.json,logout/test_receive.json

# have to restart the websocket connection because rate limit of verify_email call is reached
{reset}

# VIRTUAL ACCOUNT OPENING (VRTJ TO FAIL KNOWLEDGE TEST)
verify_email/test_send.json,verify_email/test_receive.json, 'test-jp@binary.com', 'account_opening'
new_account_virtual/test_send.json,new_account_virtual/test_receive_vrtj.json,_get_token('test-jp@binary.com'), 'test-jp@binary.com', 'jp'
authorize/test_send.json,authorize/test_receive_vrtj.json,_get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'test-jp@binary.com'

# READ SCOPE CALLS (VRTJ)
balance/test_send.json,balance/test_receive.json, '1000000\\.00', 'JPY', _get_stashed('authorize/authorize/loginid')
payout_currencies/test_send.json,payout_currencies/test_receive_vrt.json, 'JPY', 1
!payout_currencies/test_send.json,payout_currencies/test_receive_vrt.json, 'USD', 1
get_settings/test_send.json,get_settings/test_receive_vrtj_before.json
get_account_status/test_send.json,get_account_status/test_receive.json

# TESTS TO RETURN ERROR (VRTJ)
get_limits/test_send.json,get_limits/test_receive_error.json
get_financial_assessment/test_send.json,get_financial_assessment/test_receive_vrt.json

# REAL ACCOUNT OPENING (JP)
new_account_japan/test_send.json,new_account_japan/test_receive.json, 'Susan'
get_settings/test_send.json,get_settings/test_receive_vrtj_after.json, 'jp_knowledge_test_pending', 'test-jp@binary.com'
jp_knowledge_test/test_send.json,jp_knowledge_test/test_receive.json, '8', 'fail'
!jp_knowledge_test/test_send.json,jp_knowledge_test/test_receive_error.json, '230', 'succeed'
get_settings/test_send.json,get_settings/test_receive_vrtj_fail.json

# VIRTUAL ACCOUNT OPENING (VRTJ TO PASS KNOWLEDGE TEST)
verify_email/test_send.json,verify_email/test_receive.json, 'test-jp2@binary.com', 'account_opening'
new_account_virtual/test_send.json,new_account_virtual/test_receive_vrtj.json,_get_token('test-jp2@binary.com'), 'test-jp2@binary.com', 'jp'
authorize/test_send.json,authorize/test_receive_vrtj.json,_get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'test-jp2@binary.com'

# REAL ACCOUNT OPENING (JP)
new_account_japan/test_send.json,new_account_japan/test_receive_error.json, 'Susan'
new_account_japan/test_send.json,new_account_japan/test_receive.json, 'Julie'
jp_knowledge_test/test_send.json,jp_knowledge_test/test_receive.json, '12', 'pass'
get_settings/test_send.json,get_settings/test_receive_vrtj_after.json, 'jp_activation_pending', 'test-jp2@binary.com'

# VIRTUAL ACCOUNT OPENING FOR (MX)
verify_email/test_send.json,verify_email/test_receive.json, 'test-mx@binary.com', 'account_opening'
new_account_virtual/test_send.json,new_account_virtual/test_receive.json,_get_token('test-mx@binary.com'), 'test-mx@binary.com', 'gb'

# REAL ACCOUNT OPENING (MX)
authorize/test_send.json,authorize/test_receive_vrtc.json,_get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'test-mx@binary.com'
new_account_real/test_send.json,new_account_real/test_receive_mx.json, 'John', 'gb'
authorize/test_send.json,authorize/test_receive_mx.json,_get_stashed('new_account_real/new_account_real/oauth_token'), 'test-mx@binary.com', 'John'
balance/test_send.json,balance/test_receive.json, '0\\.00', '', _get_stashed('authorize/authorize/loginid')
payout_currencies/test_send.json,payout_currencies/test_receive_vrt.json, '(USD|GBP)', 2
!payout_currencies/test_send.json,payout_currencies/test_receive_vrt.json, '(EUR|GBP)', 2

# PAYMENT SCOPE CALLS (MX)
cashier/test_send_deposit.json,cashier/test_receive_currency_error.json
set_account_currency/test_send.json,set_account_currency/test_receive.json, 'GBP'
payout_currencies/test_send.json,payout_currencies/test_receive_vrt.json, 'GBP', 1
!payout_currencies/test_send.json,payout_currencies/test_receive_vrt.json, 'EUR', 1
cashier/test_send_deposit.json,cashier/test_receive_ukgc_error.json
tnc_approval/test_send_ukgc.json,tnc_approval/test_receive.json
[% _change_status(_get_stashed('authorize/authorize/loginid'), 'set', 'age_verification'); _change_status(_get_stashed('authorize/authorize/loginid'), 'set', 'ukrts_max_turnover_limit_not_set') %]cashier/test_send_deposit.json,cashier/test_receive_max_turnover.json
# set_self_exclusion for max_30day_turnover should remove ukrts_max_turnover_limit_not_set status
set_self_exclusion/test_send.json,set_self_exclusion/test_receive.json
balance/test_send.json,balance/test_receive.json, '0\\.00', 'GBP', _get_stashed('authorize/authorize/loginid')

# VIRTUAL ACCOUNT OPENING (VRTC)
verify_email/test_send.json,verify_email/test_receive.json, 'test2@binary.com', 'account_opening'
new_account_virtual/test_send.json,new_account_virtual/test_receive.json,_get_token('test2@binary.com'), 'test2@binary.com', 'au'
verify_email/test_send.json,verify_email/test_receive.json, 'test2@binary.com', 'reset_password'
reset_password/test_send_vrt.json,reset_password/test_receive.json,_get_token('test2@binary.com'), 'Abc123'
