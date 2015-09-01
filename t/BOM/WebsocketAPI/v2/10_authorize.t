use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $t = build_mojo_test();

my $faked_token = 'ABC';
$t = $t->send_ok({json => {authorize => $faked_token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{error}->{code}, 'InvalidToken';
test_schema('authorize', $authorize);

my $token = BOM::Platform::SessionCookie->new(
    client_id       => 1,
    loginid         => "CR2002",
    email           => 'CR2002@binary.com',
    expiration_time => time() + 600,
    scopes          => ['price', 'trade'],
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
$authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'CR2002@binary.com';
is $authorize->{authorize}->{loginid}, 'CR2002';
test_schema('authorize', $authorize);

$t->finish_ok;

done_testing();
