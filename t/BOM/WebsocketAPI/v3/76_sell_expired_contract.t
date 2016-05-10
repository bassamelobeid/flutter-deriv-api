use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $t = build_mojo_test();

# check for authenticated call
$t = $t->send_ok({json => {sell_expired => 1}})->message_ok;
my $response = decode_json($t->message->[1]);

is $response->{error}->{code},    'AuthorizationRequired';
is $response->{error}->{message}, 'Please log in.';

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

my $token = BOM::Platform::SessionCookie->new(
    loginid => $test_client->loginid,
    email   => 'unit_test@binary.com',
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'unit_test@binary.com';
is $authorize->{authorize}->{loginid}, $test_client->loginid;

# wrong call
$t = $t->send_ok({json => {sell_expired => 2}})->message_ok;
$response = decode_json($t->message->[1]);

is $response->{error}->{code}, 'InputValidationFailed';

$t = $t->send_ok({json => {sell_expired => 1}})->message_ok;
$response = decode_json($t->message->[1]);

is $response->{echo_req}->{sell_expired}, 1;

done_testing();
