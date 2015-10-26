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
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::Client;

my $t = build_mojo_test();

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $token = BOM::Platform::SessionCookie->new(
    loginid => $test_client->loginid,
    email   => $test_client->email,
)->token;

# authorize ok
$t = $t->send_ok({json => {authorize => $token}})->message_ok;

$t = $t->send_ok({json => {get_settings => 1}})->message_ok;
my $res = decode_json($t->message->[1]);
ok($res->{get_settings});
my $old_address_line_1 = $res->{get_settings}->{address_line_1};
ok $old_address_line_1;
test_schema('get_settings', $res);

## test virtual
my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$token = BOM::Platform::SessionCookie->new(
    loginid => $test_client_vr->loginid,
    email   => $test_client_vr->email,
)->token;

# authorize ok
$t = $t->send_ok({json => {authorize => $token}})->message_ok;

$t = $t->send_ok({json => {get_settings => 1}})->message_ok;
$res = decode_json($t->message->[1]);
ok($res->{get_settings});
ok $res->{get_settings}->{email};
ok not $res->{get_settings}->{address_line_1};    # do not have address for virtual
test_schema('get_settings', $res);

$t->finish_ok;

done_testing();
