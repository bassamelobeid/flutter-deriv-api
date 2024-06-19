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
    title             => "accounts.t",
    test_app          => 'Binary::WebSocketAPI',
    suite_schema_path => __DIR__ . '/config/',
);

set_language 'EN';

# Perform Authentication
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test@binary.com', 'account_opening';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    $suite->get_token('test@binary.com'), 'test@binary.com', 'id';
test_sendrecv_params 'authorize/test_send.json', 'authorize/test_receive_vrtc.json',
    $suite->get_stashed('new_account_virtual/new_account_virtual/oauth_token'), 'test@binary.com';

# Test POC one-tick
test_sendrecv_params 'contract/test_send_subscribe_poc.json', 'contract/test_receive_poc_with_subscription.json';
test_sendrecv_params 'contract/test_send_subscribe_poc.json', 'contract/test_receive_error_subscribed_poc.json';

finish;

