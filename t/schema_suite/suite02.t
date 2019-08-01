use strict;
use warnings;
use Test::Most;
use Dir::Self;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use lib "$Bin";

use BOM::Test::Suite::DSL;

my $suite = start(
    title             => "suite02.t",
    test_app          => 'BOM::RPC::Transport::HTTP',
    suite_schema_path => __DIR__ . '/config/',
);
sub _get_token   { return $suite->get_token(@_); }
sub _get_stashed { return $suite->get_stashed(@_); }

set_language 'EN';

# VIRTUAL ACCOUNT OPENING FOR (MX)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test+mx@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    _get_token('test+mx@binary.com'), 'gb', 'test\\\\+mx@binary.com';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
    _get_stashed('new_account_virtual/oauth_token'), 'gb', 'test\\\\+mx@binary.com';

# REAL ACCOUNT OPENING (MX)
$SIG{'__WARN__'} = sub { like shift, qr/signup validation proveid fail:/ };    # proveid will fail for these test clients

test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_mx.json',
    _get_stashed('authorize/stash/token'), 'Example First Name MX', 'gb';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_mx.json',
    _get_stashed('new_account_real/oauth_token'), 'gb', 'test\\\\+mx@binary.com';
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive.json', _get_stashed('authorize/stash/token'), '(USD|GBP)', 2;

# PAYMENT SCOPE CALLS (MX)
test_sendrecv_params 'cashier/test_send_deposit.json', 'cashier/test_receive_currency_error.json', _get_stashed('new_account_real/oauth_token');

test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json',
    _get_stashed('new_account_real/oauth_token'), 'GBP';
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive.json', _get_stashed('authorize/stash/token'), '(GBP)', 1;

test_sendrecv_params 'cashier/test_send_deposit.json', 'cashier/test_receive_ukgc_error.json', _get_stashed('new_account_real/oauth_token');

# ADMIN SCOPE CALLS (MX)
test_sendrecv_params 'tnc_approval/test_send_ukgc.json', 'tnc_approval/test_receive.json', _get_stashed('new_account_real/oauth_token');

# PAYMENT SCOPE CALLS (MX)
$suite->change_status(_get_stashed('new_account_real/client_id'), 'set', 'age_verification');
$suite->change_status(_get_stashed('new_account_real/client_id'), 'set', 'max_turnover_limit_not_set');
test_sendrecv_params 'cashier/test_send_deposit.json', 'cashier/test_receive_max_turnover.json', _get_stashed('new_account_real/oauth_token');
# set_self_exclusion for max_30day_turnover should remove max_turnover_limit_not_set status,
# if we make call from here it will try to connect to doughflow, enable this when we can test doughflow
# on qa and test
# &BOM::RPC::v3::Accounts::set_self_exclusion({client=>BOM::User::Client->new({loginid => _get_stashed('new_account_real/client_id')}), args=>{max_30day_turnover=>1000}})
# test_sendrecv_params 'cashier/test_send_deposit.json', 'cashier/test_receive_currency_error.json',
#     _get_stashed('new_account_real/oauth_token');

test_sendrecv_params 'logout/test_send.json', 'logout/test_receive.json', _get_stashed('new_account_real/oauth_token');
fail_test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_mf.json',
    _get_stashed('new_account_real/oauth_token'), 'cz', 'test\\\\+mx@binary.com';

reset_app;

test_sendrecv_params 'ticks/test_send.json', 'ticks/test_receive.json',       'R_50';
test_sendrecv_params 'ticks/test_send.json', 'ticks/test_receive_error.json', 'invalid_symbol';

test_sendrecv_params 'ticks_history/test_send_ticks_style.json', 'ticks_history/test_receive_ticks_style.json',
    'R_50', '10', '1478625842', '1478710431';

# VIRTUAL ACCOUNT OPENING (VRTC)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test+reset@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    _get_token('test+reset@binary.com'), 'be', 'test\\\\+reset@binary.com';
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test+reset@binary.com', 'reset_password';
test_sendrecv_params 'reset_password/test_send_vrt.json', 'reset_password/test_receive.json', _get_token('test+reset@binary.com'), 'Binary@123';

finish;
