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
$t = $t->send_ok({json => {reality_check => 1}})->message_ok;
my $response = decode_json($t->message->[1]);

is $response->{error}->{code},    'AuthorizationRequired';
is $response->{error}->{message}, 'Please log in.';

my $token = BOM::Platform::SessionCookie->new(
    loginid => "CR0021",
    email   => 'shuwnyuan@regentmarkets.com',
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{authorize}->{loginid}, 'CR0021';

$t = $t->send_ok({json => {reality_check => 1}})->message_ok;
$res = decode_json($t->message->[1]);
test_schema('reality_check', $res);

$t = $t->send_ok({json => {reality_check => 1}})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'RateLimit', 'Only 1 request in 10 minutes for reality check';

done_testing();

