use strict;
use warnings;
use Test::Most;
use Dir::Self;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use lib "$Bin";

use BOM::Test::Suite::DSL;

my $suite = start(
    title             => "suite01.t",
    test_app          => 'BOM::RPC::Transport::HTTP',
    suite_schema_path => __DIR__ . '/config/',
);
sub _get_token   { return $suite->get_token(@_); }
sub _get_stashed { return $suite->get_stashed(@_); }

set_language 'EN';

test_sendrecv_params 'landing_company/test_send.json', "landing_company/test_receive_$_.json", $_ foreach qw( ua de br );

test_sendrecv_params 'landing_company_details/test_send.json', 'landing_company_details/test_receive_svg.json',         'svg';
test_sendrecv_params 'landing_company_details/test_send.json', 'landing_company_details/test_receive_virtual.json',     'virtual';
test_sendrecv_params 'landing_company_details/test_send.json', 'landing_company_details/test_receive_iom.json',         'iom';
test_sendrecv_params 'landing_company_details/test_send.json', 'landing_company_details/test_receive_malta.json',       'malta';
test_sendrecv_params 'landing_company_details/test_send.json', 'landing_company_details/test_receive_maltainvest.json', 'maltainvest';
test_sendrecv_params 'landing_company_details/test_send.json', 'landing_company_details/test_receive_error.json',       'unknown';
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive.json', '', '(USD|EUR|GBP|AUD|BTC|LTC|BCH|ETH|UST|USB|IDK)',
    11;
test_sendrecv_params 'residence_list/test_send.json', 'residence_list/test_receive.json';
test_sendrecv_params 'states_list/test_send.json',    'states_list/test_receive.json';

# VIRTUAL ACCOUNT OPENING FOR (CR)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test-rpc@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    _get_token('test-rpc@binary.com'), 'zm', 'test-rpc@binary.com';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
    _get_stashed('new_account_virtual/oauth_token'), 'zm', 'test-rpc@binary.com';
# fail_test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
#     _get_token('test@binary.com'), 'zm', 'test@binary.com';

# READ SCOPE CALLS (VRTC)
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive.json', _get_stashed('authorize/stash/token'), 'USD', 1;
test_sendrecv_params 'login_history/test_send.json', 'login_history/test_receive.json', _get_stashed('authorize/stash/token');
test_sendrecv_params 'get_settings/test_send.json', 'get_settings/test_receive_vrtc.json', 'Zambia', 'zm', _get_stashed('authorize/stash/token');
test_sendrecv_params 'get_account_status/test_send.json', 'get_account_status/test_receive.json', _get_stashed('authorize/stash/token');
test_sendrecv_params 'profit_table/test_send.json', 'profit_table/test_receive_error_unauth.json', '12345', 1420041600, 1514736000;
test_sendrecv_params 'profit_table/test_send.json', 'profit_table/test_receive.json', _get_stashed('authorize/stash/token'), 1420041600, 1514736000;
test_sendrecv_params 'statement/test_send.json', 'statement/test_receive_error_unauth.json', '12345';
test_sendrecv_params 'statement/test_send.json', 'statement/test_receive.json',              _get_stashed('authorize/stash/token');
test_sendrecv_params 'portfolio/test_send.json', 'portfolio/test_receive_error_unauth.json', '12345';
test_sendrecv_params 'portfolio/test_send.json', 'portfolio/test_receive.json',              _get_stashed('authorize/stash/token');
test_sendrecv_params 'balance/test_send.json',   'balance/test_receive_error_unauth.json',   '12345';
test_sendrecv_params 'balance/test_send.json',   'balance/test_receive.json',                _get_stashed('authorize/stash/token');

# TRADE SCOPE CALLS (VRTC)
test_sendrecv_params 'topup_virtual/test_send.json', 'topup_virtual/test_receive_error.json', _get_stashed('authorize/stash/token');
test_sendrecv_params 'buy/test_send.json', 'buy/test_receive.json', _get_stashed('new_account_virtual/oauth_token'), '99\\\\d{2}\\\\.\\\\d{2}';

# TESTS TO RETURN ERROR (VRTC)
test_sendrecv_params 'set_settings/test_send.json', 'set_settings/test_receive_error.json', _get_stashed('new_account_virtual/oauth_token');
test_sendrecv_params 'get_financial_assessment/test_send.json', 'get_financial_assessment/test_receive_vrt.json',
    _get_stashed('new_account_virtual/oauth_token');

# ADMIN SCOPE CALLS (GENERAL)
test_sendrecv_params 'api_token/test_send_create.json', 'api_token/test_receive_create.json', _get_stashed('authorize/stash/token'), 'test-rpc';
test_sendrecv_params 'api_token/test_send.json', 'api_token/test_receive.json',
    _get_stashed('authorize/stash/token'), _get_stashed('api_token/tokens/0/token'), 'test-rpc';
test_sendrecv_params 'api_token/test_send_delete.json', 'api_token/test_receive_delete.json',
    _get_stashed('authorize/stash/token'), _get_stashed('api_token/tokens/0/token');
test_sendrecv_params 'app_register/test_send.json', 'app_register/test_receive.json', _get_stashed('authorize/stash/token');
test_sendrecv_params 'app_get/test_send.json', 'app_get/test_receive.json',
    _get_stashed('authorize/stash/token'), _get_stashed('app_register/app_id');

# REAL ACCOUNT OPENING (CR)
test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_cr.json',
    _get_stashed('authorize/stash/token'), 'Example First Name', 'zm';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_cr.json',
    _get_stashed('new_account_real/oauth_token'), 'zm', 'test-rpc@binary.com';
test_sendrecv_params 'buy/test_send.json', 'buy/test_receive_nobalance.json', _get_stashed('new_account_real/oauth_token');

# ADMIN SCOPE CALLS (CR)
# TEMPORARY: Need to call this before sub account as sub account return all crypto currencies as well
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive.json',
    _get_stashed('authorize/stash/token'), '(USD|EUR|GBP|AUD|BTC|LTC|BCH|ETH|UST|USB|IDK)', 11;
# ADMIN SCOPE CALLS (CR)
test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json',
    _get_stashed('new_account_real/oauth_token'), 'USD';
test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive_error.json',
    _get_stashed('new_account_real/oauth_token'), 'XXX';
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive.json', _get_stashed('authorize/stash/token'), 'USD', 1;
test_sendrecv_params 'set_financial_assessment/test_send.json', 'set_financial_assessment/test_receive.json',
    _get_stashed('new_account_real/oauth_token');
test_sendrecv_params 'get_financial_assessment/test_send.json', 'get_financial_assessment/test_receive.json',
    _get_stashed('new_account_real/oauth_token'),       _get_stashed('set_financial_assessment/total_score'),
    _get_stashed('set_financial_assessment/cfd_score'), _get_stashed('set_financial_assessment/financial_information_score'),
    _get_stashed('set_financial_assessment/trading_score');
test_sendrecv_params 'set_settings/test_send.json',       'set_settings/test_receive.json',       _get_stashed('new_account_real/oauth_token');
test_sendrecv_params 'set_self_exclusion/test_send.json', 'set_self_exclusion/test_receive.json', _get_stashed('new_account_real/oauth_token');

# READ SCOPE CALLS (CR)
test_sendrecv_params 'get_self_exclusion/test_send.json', 'get_self_exclusion/test_receive.json', _get_stashed('new_account_real/oauth_token');
fail_test_sendrecv_params 'get_self_exclusion/test_send.json', 'get_self_exclusion/test_receive_to_fail.json',
    _get_stashed('new_account_real/oauth_token');

# VIRTUAL ACCOUNT OPENING FOR (MLT)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test+mlt@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    _get_token('test+mlt@binary.com'), 'cz', 'test\\\\+mlt@binary.com';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
    _get_stashed('new_account_virtual/oauth_token'), 'cz', 'test\\\\+mlt@binary.com';

# REAL ACCOUNT OPENING (MLT)
test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_mlt.json',
    _get_stashed('authorize/stash/token'), 'Example First Name MLT', 'cz';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_mlt.json',
    _get_stashed('new_account_real/oauth_token'), 'cz', 'test\\\\+mlt@binary.com';
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive.json',
    _get_stashed('authorize/stash/token'), '(USD|EUR|GBP)', 3;

# READ SCOPE CALLS (MLT)
test_sendrecv_params 'reality_check/test_send.json', 'reality_check/test_receive.json', _get_stashed('authorize/stash/token');

# FINANCIAL ACCOUNT OPENING (MF)
test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive_error.json',
    _get_stashed('authorize/stash/token'), 'Example First Name MLT', 'cz', '0';
test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive.json',
    _get_stashed('authorize/stash/token'), 'Example First Name MLT', 'cz', '1';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_mf.json',
    _get_stashed('new_account_maltainvest/oauth_token'), 'cz', 'test\\\\+mlt@binary.com';
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive.json',
    _get_stashed('authorize/stash/token'), '(USD|EUR|GBP)', 3;


# ADMIN SCOPE CALLS (MF)
test_sendrecv_params 'change_password/test_send.json', 'change_password/test_receive_error.json',
    _get_stashed('new_account_maltainvest/oauth_token'), 'Binary@1', 'Binary@1';
test_sendrecv_params 'change_password/test_send.json', 'change_password/test_receive_error.json',
    _get_stashed('new_account_maltainvest/oauth_token'), 'Binary@1', 'binary1';
test_sendrecv_params 'change_password/test_send.json', 'change_password/test_receive_error.json',
    _get_stashed('new_account_maltainvest/oauth_token'), 'binary1', 'Binary@1';
test_sendrecv_params 'change_password/test_send.json', 'change_password/test_receive.json',
    _get_stashed('new_account_maltainvest/oauth_token'), 'Binary@1', 'Binary@12';

test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test+mlt@binary.com', 'reset_password';
test_sendrecv_params 'reset_password/test_send_real.json', 'reset_password/test_receive.json', _get_token('test+mlt@binary.com'), 'Binary@123';

finish;
