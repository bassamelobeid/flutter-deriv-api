use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::SessionCookie;

my $t = build_mojo_test();

# check for authenticated call
$t = $t->send_ok({
        json => {
            transaction => 1,
            subscribe   => 1
        }})->message_ok;
my $response = decode_json($t->message->[1]);

is $response->{error}->{code},    'AuthorizationRequired';
is $response->{error}->{message}, 'Please log in.';

my $token = BOM::Platform::SessionCookie->new(
    loginid => "CR0021",
    email   => 'shuwnyuan@regentmarkets.com',
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'shuwnyuan@regentmarkets.com';
is $authorize->{authorize}->{loginid}, 'CR0021';

# wrong call - no subscribe
$t = $t->send_ok({json => {transaction => 1}})->message_ok;
$response = decode_json($t->message->[1]);

is $response->{error}->{code}, 'InputValidationFailed';

$t = $t->send_ok({
        json => {
            transaction => 1,
            subscribe   => 1
        }})->message_ok;
$response = decode_json($t->message->[1]);

ok $response->{transaction}->{id};

done_testing();

