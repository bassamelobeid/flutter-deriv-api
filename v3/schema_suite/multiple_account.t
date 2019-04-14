use strict;
use warnings;
use Test::Most;
use Dir::Self;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use lib "$Bin";

use BOM::Test::Suite::DSL;

my $suite = start(
    title             => "multiple_account.t",
    test_app          => 'Binary::WebSocketAPI',
    suite_schema_path => __DIR__ . '/config/',
);

set_language 'EN';

my $placeholder;    # a variable to store temporary results in for reuse later on

# Generic rules
# - virtual account can only upgrade once to real account
# - Real account cannot open new account if previous account
#   currency is not set
# - Real account allowed only one fiat currency
# - Real new account cannot have same currency as existing
#   account
# - Real new account can have only each type of crypto
#   currency, if crypto currency is allowed by landing company
#   for e.g. BTC -> ETH allowed, BTC -> BTC not allowed

######
# CR
######

# CR specific rules
# - CR client not allowed to open maltainvest account

# VIRTUAL ACCOUNT OPENING
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'testmultiple@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('testmultiple@binary.com'), 'testmultiple@binary.com', 'id';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
    $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'testmultiple@binary.com';
# not allowed to make virtual account with same email
fail_test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('testmultiple@binary.com'), 'testmultiple@binary.com', 'id';

# REAL ACCOUNT OPENING
test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_cr.json', 'Howdee', 'id', '+69876543000';

$placeholder = $suite->get_stashed('new_account_real/new_account_real/oauth_token');

# virtual client not allowed to make multiple real account call
fail_test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_cr.json', 'Howdee', 'id', '+69876543000';

# authorize real account to make multiple accounts
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_cr.json', $placeholder, 'testmultiple@binary.com', 'Howdee';
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json', '(USD|EUR|GBP|AUD|BTC|LTC|BCH|ETH|UST|USB)', 10;
# will fail as currency for existing client is not set
fail_test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_cr.json', 'Howdee', 'id', '+69876543000';

# set account currency
test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'USD';
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json', 'USD', 1;

# another account can be made, and any provided client data will be ignore
test_sendrecv_params 'new_account_real/test_send_placeholder.json', 'new_account_real/test_receive_cr.json',
    'Howde', 'Pann', '1980-11-31', 'id', 'Jakarta', '+612345678';
test_sendrecv_params 'get_settings/test_send.json', 'new_account_real/test_recieve_get_settings.conf';
# allowed to make mutliple call now as currency is set for existing account
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_cr.json',
    $suite->get_stashed('new_account_real/new_account_real/oauth_token'), 'testmultiple@binary.com', 'Howdee';

# will fail as USD already set for one of client
fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'USD';
# we only allow one fiat currency so this will also fail
fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'EUR';
# will fail as accounts exhausted
fail_test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_cr.json', 'Howdee', 'id', '+69876543000';

# fail to set currency not in allowed currencies for landing company
fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'ETC';
# ok to set BTC
test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'BTC';
# not allowed to set currency again
fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'USD';

# not allowed to make maltainvest as new sibling
fail_test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive.json', '1', 'Howdee', 'dk', '+61234567000';

test_sendrecv_params 'logout/test_send.json', 'logout/test_receive.json';

######
# MLT
######

# MLT specific rules
# - MLT can only upgrade to financial once
# - MLT can have currencies irrespective of what MF has
#   as checks are landing company specific

# VIRTUAL ACCOUNT OPENING
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test-multiple-mlt@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('test-multiple-mlt@binary.com'), 'test-multiple-mlt@binary.com', 'dk';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
    $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'test-multiple-mlt@binary.com';

test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_mlt.json', 'Howdee', 'dk', '+69876543003';

$placeholder = $suite->get_stashed('new_account_real/new_account_real/oauth_token');

# virtual not allowed to make multiple new accounts
fail_test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_mlt.json', 'Howdee', 'dk', '+69876543000';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_mlt.json', $placeholder, 'test-multiple-mlt@binary.com', 'Howdee';
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json', '(USD|EUR|GBP)', 3;

# not allowed as previous account has no currency set
fail_test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_mlt.json', 'Howdee', 'dk', '+69876543000';

# not allowed as not supported yet
fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'LTC';
fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'ETH';
fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'BTC';
fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'BCH';
# set account currency
test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'EUR';
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json', 'EUR', 1;

# still not allowed as fiat currency exhausted and MLT has no cryptocurrency
fail_test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_mlt.json', 'Howdee', 'dk', '+69876543000';

test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive_error.json', '0', 'Howdee', 'dk', '+61234567001';
# mlt able to upgrade to maltainvest
test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive.json', '1', 'Howdee', 'dk', '+61234567002';
$placeholder = $suite->get_stashed('new_account_maltainvest/new_account_maltainvest/oauth_token');

# not allowed to create mutlpile invest account from mlt
fail_test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive.json', '1', 'Howdee', 'dk', '+61234567003';

test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_mf.json', $placeholder, 'test-multiple-mlt@binary.com', 'Howdee';

# not able to create as previous currency not set
fail_test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive.json', '1', 'Howdee', 'dk', '+61234567004';
# able to set currency, doesn't depend on mlt account
fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'LTC';
fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'BTC';
fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'BCH';
test_sendrecv_params 'set_account_currency/test_send.json',      'set_account_currency/test_receive.json', 'EUR';

# not able to create as fiat currency exhausted and crypto not yet supported for MF
fail_test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive.json', '1', 'Howdee', 'dk', '+61234567005';
test_sendrecv_params 'logout/test_send.json', 'logout/test_receive.json';

reset_app;

######
# MF
######

test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test-multiple-mf@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('test-multiple-mf@binary.com'), 'test-multiple-mf@binary.com', 'de';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
    $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'test-multiple-mf@binary.com';

# for germany we don't have gaming company so it should fail
fail_test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_mlt.json', 'MFName', 'de', '+69876543000';

test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive.json', '1', 'MFName', 'de', '+6123456700011';
$placeholder = $suite->get_stashed('new_account_maltainvest/new_account_maltainvest/oauth_token');

# not allowed multiple upgrade from financial
fail_test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive.json', '1', 'MFName', 'de', '+61234567006';

test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_mf.json', $placeholder, 'test-multiple-mf@binary.com', 'MFName';

# not allowed as currency not set for existing account
fail_test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive.json', '1', 'MFName', 'de', '+61234567007';

fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'BTC';
fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'BCH';
fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'LTC';
test_sendrecv_params 'set_account_currency/test_send.json',      'set_account_currency/test_receive.json', 'EUR';

# still not allowed as all accounts exhausted
fail_test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive.json', '1', 'MFName', 'de', '+61234567008';

#####
# MX
#####

# VIRTUAL ACCOUNT OPENING FOR (MX)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test-multiple-mx@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('test-multiple-mx@binary.com'), 'test-multiple-mx@binary.com', 'gb';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
    $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'test-multiple-mx@binary.com';
fail_test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('test-multiple-mx@binary.com'), 'test-multiple-mx@binary.com', 'gb';

# REAL ACCOUNT OPENING (MX)

test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_mx.json', 'Johny', 'gb', '+69876543000';
$placeholder = $suite->get_stashed('new_account_real/new_account_real/oauth_token');

# not allowed to open it again from virtual
fail_test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_mx.json', 'Johny', 'gb', '+69876543000';

# authorize real account to make multiple accounts
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_mx.json', $placeholder, 'test-multiple-mx@binary.com', 'Johny';

# will fail as currency for existing client is not set
fail_test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_mx.json', 'Johny', 'gb', '+69876543000';

# crypto currencies not allowed
fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'BTC';

test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'GBP';
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json', 'GBP', 1;

# will fail as exhausted
fail_test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_mx.json', 'Johny', 'gb', '+69876543000';

finish;
