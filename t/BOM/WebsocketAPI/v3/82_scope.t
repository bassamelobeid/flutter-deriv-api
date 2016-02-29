use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test create_test_user/;

use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Database::Model::OAuth;

my $t    = build_mojo_test();
my $cr_1 = create_test_user();

## read will not allow to access trade, payments and admin
my ($token) = BOM::Database::Model::OAuth->new()->store_access_token_only('binarycom', $cr_1, 'read');
$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{loginid}, $cr_1;
$t = $t->send_ok({
        json => {
            buy   => '1' x 32,
            price => 1,
        }});
$t = $t->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'PermissionDenied', 'PermissionDenied b/c it is trade';
$t = $t->send_ok({json => {get_account_status => 1}})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{get_account_status}, 'get_account_status is read scope';

($token) = BOM::Database::Model::OAuth->new()->store_access_token_only('binarycom', $cr_1, 'trade');
$t = $t->send_ok({json => {authorize => $token}})->message_ok;
$authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{loginid}, $cr_1;
$t = $t->send_ok({json => {get_account_status => 1}})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'PermissionDenied', 'PermissionDenied b/c it is read';

$t->finish_ok;

done_testing();
