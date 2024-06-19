use strict;
use warnings;
use Test::Most;
use Dir::Self;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use lib "$Bin";
use utf8;

use BOM::Test::Suite::DSL;

my $suite = start(
    title             => "identity_verification.t",
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

# REAL ACCOUNT OPENING (CR)
test_sendrecv_params 'new_account_real/test_send.json', 'new_account_real/test_receive_cr.json', 'Sarah', 'id', '+61234567001';

## Set POI Age_verification and allow_document_upload
$suite->change_status($suite->get_stashed('authorize/authorize/loginid'), 'set',   'poi_name_mismatch');
$suite->change_status($suite->get_stashed('authorize/authorize/loginid'), 'clear', 'age_verification');

# get token
my $placeholder = $suite->get_stashed('new_account_real/new_account_real/oauth_token');

# authorize real account
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_cr.json', $placeholder, 'test1@binary.com', 'Sarah';

# call IDV
test_sendrecv_params 'identity_verification_document_add/test_send.json', 'identity_verification_document_add/test_receive.json', $placeholder;

finish;
