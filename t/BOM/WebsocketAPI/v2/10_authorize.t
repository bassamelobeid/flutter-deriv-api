use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::SessionCookie;

my $t = build_mojo_test();

## test those requires auth
$t = $t->send_ok({json => {balance => 1}})->message_ok;
my $balance = decode_json($t->message->[1]);
is($balance->{error}->{code}, 'AuthorizationRequired');
test_schema('balance', $balance);

## test with faked token
my $faked_token = 'ABCDABCDABCDABCDABCDABCDABCDABCDABCDABCDABCDABCD';
$t = $t->send_ok({json => {authorize => $faked_token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{error}->{code}, 'InvalidToken';
test_schema('authorize', $authorize);

## test with good one
my $token = BOM::Platform::SessionCookie->new(
    client_id       => 1,
    loginid         => "CR2002",
    email           => 'sy@regentmarkets.com',
    expiration_time => time() + 600,
    scopes          => ['price', 'trade'],
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
$authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'sy@regentmarkets.com';
is $authorize->{authorize}->{loginid}, 'CR2002';
test_schema('authorize', $authorize);

## it's ok after authorize
$t = $t->send_ok({json => {balance => 1}})->message_ok;
$balance = decode_json($t->message->[1]);
ok($balance->{balance});
test_schema('balance', $balance);

$t->finish_ok;

done_testing();
