use strict;
use warnings;
use Test::Most;
use Dir::Self;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use lib "$Bin";

use BOM::Test::Suite::DSL;

my $suite = start(
    title             => "copytrading.t",
    test_app          => 'Binary::WebSocketAPI',
    suite_schema_path => __DIR__ . '/config/',
);

set_language 'EN';

# TRADER VIRTUAL ACCOUNT OPENING FOR (CR)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'trader@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('trader@binary.com'), 'trader@binary.com', 'id';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
    $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'trader@binary.com';

# TRADER REAL ACCOUNT OPENING (CR)
test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_cr.json', 'Peter', 'id', '+61 2 9876 5432';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_cr.json',
    $suite->get_stashed('new_account_real/new_account_real/oauth_token'), 'trader@binary.com', 'Peter';

test_sendrecv_params 'copytrading_statistics/test_send.json', 'copytrading_statistics/test_receive_trader_does_not_allow_copiers.json',
    $suite->get_stashed('authorize/authorize/loginid');
test_sendrecv_params 'set_settings/test_send.json',           'set_settings/test_receive.json';
test_sendrecv_params 'copytrading_statistics/test_send.json', 'copytrading_statistics/test_receive_trader_has_no_account.json',
    $suite->get_stashed('authorize/authorize/loginid');

$suite->free_gift($suite->get_stashed('new_account_real/new_account_real/client_id'));
test_sendrecv_params 'balance/test_send.json', 'balance/test_receive.json', 10000, 'USD', $suite->get_stashed('authorize/authorize/loginid');

test_sendrecv_params 'proposal/test_send_buy.json', 'proposal/test_receive_buy.json';
test_sendrecv_params 'buy/test_send.json',          'buy/test_receive.json', $suite->get_stashed('proposal/proposal/id'), 9948.51;
test_sendrecv_params 'balance/test_send.json',      'balance/test_receive.json', 9948.51, 'USD', $suite->get_stashed('authorize/authorize/loginid');

test_sendrecv_params 'copytrading_statistics/test_send.json', 'copytrading_statistics/test_receive.json',
    $suite->get_stashed('authorize/authorize/loginid');

test_sendrecv_params 'api_token/test_send_create_read.json', 'api_token/test_receive_create_read.json', 'test';
test_sendrecv_params 'api_token/test_send.json', 'api_token/test_receive_read.json', $suite->get_stashed('api_token/api_token/tokens/0/token');

# SET ALLOW_COPIERS FLAG
test_sendrecv_params 'set_settings/test_send.json', 'set_settings/test_receive.json';

# COPIER VIRTUAL ACCOUNT OPENING FOR (CR)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'copier@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('copier@binary.com'), 'copier@binary.com', 'id';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
    $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'copier@binary.com';

# COPIER REAL ACCOUNT OPENING (CR)
test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_cr.json', 'Vasya', 'id', '+61 2 9876 5438';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_cr.json',
    $suite->get_stashed('new_account_real/new_account_real/oauth_token'), 'copier@binary.com', 'Vasya';

$suite->free_gift($suite->get_stashed('new_account_real/new_account_real/client_id'));
test_sendrecv_params 'balance/test_send.json', 'balance/test_receive.json', 10000, 'USD', $suite->get_stashed('authorize/authorize/loginid');

test_sendrecv_params 'copytrading_list/test_send.json', 'copytrading_list/test_receive_empty.json';

test_sendrecv_params 'copy_start/test_send.json', 'copy_start/test_receive.json', $suite->get_stashed('api_token/api_token/tokens/0/token');

test_sendrecv_params 'copytrading_list/test_send.json', 'copytrading_list/test_receive_trader.json';

test_sendrecv_params 'copy_stop/test_send.json', 'copy_stop/test_receive.json', $suite->get_stashed('api_token/api_token/tokens/0/token');

finish;
