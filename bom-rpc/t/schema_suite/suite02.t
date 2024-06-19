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
    test_app          => 'BOM::RPC::Transport::Redis',
    suite_schema_path => __DIR__ . '/config/',
);
sub _get_token   { return $suite->get_token(@_); }
sub _get_stashed { return $suite->get_stashed(@_); }

set_language 'EN';

test_sendrecv_params 'ticks/test_send.json', 'ticks/test_receive.json',       'R_50';
test_sendrecv_params 'ticks/test_send.json', 'ticks/test_receive_error.json', 'invalid_symbol';

test_sendrecv_params 'ticks_history/test_send_ticks_style.json', 'ticks_history/test_receive_ticks_style.json',
    'R_50', '10', '1478625842', '1478710431';

# VIRTUAL ACCOUNT OPENING (VRTC)
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test+reset@binary.com', 'account_opening', 'email';
test_sendrecv_params 'new_account_virtual/test_send.json', 'new_account_virtual/test_receive.json',
    _get_token('test+reset@binary.com'), 'es', 'test\\\\+reset@binary.com';
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test+reset@binary.com', 'reset_password', 'email';
test_sendrecv_params 'reset_password/test_send_vrt.json', 'reset_password/test_receive.json', _get_token('test+reset@binary.com'), 'Binary@123';

test_sendrecv 'payment_methods/test_send_payment_methods.json', 'payment_methods/test_receive_empty_list.json';

finish;
