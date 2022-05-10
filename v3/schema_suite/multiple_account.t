use strict;
use warnings;
use Test::Most;
use Dir::Self;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use lib "$Bin";

use BOM::Test::Suite::DSL;
use BOM::Test::Data::Utility::CryptoTestDatabase qw(:init);

use LandingCompany::Registry;

my $suite = start(
    title             => "multiple_account.t",
    test_app          => 'Binary::WebSocketAPI',
    suite_schema_path => __DIR__ . '/config/',
);

set_language 'EN';

my @currencies = LandingCompany::Registry::all_currencies();
my $currencies = sprintf("(%s)", join("|", @currencies));
my $length     = scalar @currencies;

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
test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_cr.json', 'Howdee', 'id', '+61298765432';

$placeholder = $suite->get_stashed('new_account_real/new_account_real/oauth_token');

# virtual client not allowed to make multiple real account call
fail_test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_cr.json', 'Howdee', 'id', '+61298765432';

# authorize real account to make multiple accounts
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_cr.json', $placeholder, 'testmultiple@binary.com', 'Howdee';
test_sendrecv_params 'payout_currencies/test_send.json', 'payout_currencies/test_receive_vrt.json', $currencies, $length;
# will fail as currency for existing client is not set
fail_test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_cr.json', 'Howdee', 'id', '+61298765432';

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
fail_test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_cr.json', 'Howdee', 'id', '+61298765432';

# fail to set currency not in allowed currencies for landing company
fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'ETC';
# ok to set BTC
test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'BTC';

# not allowed to set currency again
fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'USD';

# not allowed to make maltainvest as new sibling
fail_test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive.json', '1', 'Howdee', 'dk', 81,
    '+61234567000',
    '1112223334';

test_sendrecv_params 'logout/test_send.json', 'logout/test_receive.json';

######
# MF
######

test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test-multiple-mf@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('test-multiple-mf@binary.com'), 'test-multiple-mf@binary.com', 'de';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
    $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'test-multiple-mf@binary.com';

# for germany we don't have gaming company so it should fail
fail_test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_mlt.json', 'MFName', 'de', '+61298765432';

test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive.json', '1', 'MFName', 'de', 'HH',
    '+61 2 9876 5434',
    '11122233344';
$placeholder = $suite->get_stashed('new_account_maltainvest/new_account_maltainvest/oauth_token');

# not allowed multiple upgrade from financial
fail_test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive.json', '1', 'MFName', 'de', 'HH',
    '+61234567006',
    '11122233344';

test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_mf.json', $placeholder, 'test-multiple-mf@binary.com', 'MFName';

# not allowed as currency not set for existing account
fail_test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive.json', '1', 'MFName', 'de', 'HH',
    '+61234567007',
    '11122233344';

fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'BTC';
fail_test_sendrecv_params 'set_account_currency/test_send.json', 'set_account_currency/test_receive.json', 'LTC';
test_sendrecv_params 'set_account_currency/test_send.json',      'set_account_currency/test_receive.json', 'EUR';

# still not allowed as all accounts exhausted
fail_test_sendrecv_params 'new_account_maltainvest/test_send.json', 'new_account_maltainvest/test_receive.json', '1', 'MFName', 'de', 'HH',
    '+61234567008',
    '11122233344';

finish;
