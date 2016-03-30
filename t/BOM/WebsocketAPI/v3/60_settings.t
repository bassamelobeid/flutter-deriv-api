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

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::Platform::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $t = build_mojo_test();

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $token = BOM::Platform::SessionCookie->new(
    loginid => $test_client->loginid,
    email   => $test_client->email,
)->token;

# test account status
my $reason = "test to set unwelcome login";
my $clerk  = 'shuwnyuan';
$test_client->set_status('unwelcome', $clerk, $reason);
$test_client->save();

# authorize ok
$t = $t->send_ok({json => {authorize => $token}})->message_ok;

$t = $t->send_ok({json => {get_account_status => 1}})->message_ok;
my $res = decode_json($t->message->[1]);
ok((grep { $_ eq 'unwelcome' } @{$res->{get_account_status}}), 'unwelcome is there');
test_schema('get_account_status', $res);

$t = $t->send_ok({json => {get_settings => 1}})->message_ok;
$res = decode_json($t->message->[1]);
ok($res->{get_settings});
my %old_data = %{$res->{get_settings}};
ok $old_data{address_line_1};
test_schema('get_settings', $res);

## set settings
my %new_data = (
    "address_line_1"   => "Test Address Line 1",
    "address_line_2"   => "Test Address Line 2",
    "address_city"     => "Test City",
    "address_state"    => "01",
    "address_postcode" => "123456",
    "phone"            => "1234567890"
);
$t = $t->send_ok({
        json => {
            set_settings => 1,
            %new_data
        }})->message_ok;
$res = decode_json($t->message->[1]);
ok($res->{set_settings});    # update OK
test_schema('set_settings', $res);

## get settings and it should be updated
$t = $t->send_ok({json => {get_settings => 1}})->message_ok;
$res = decode_json($t->message->[1]);
ok($res->{get_settings});
my %now_data = %{$res->{get_settings}};
foreach my $f (keys %new_data) {
    is $now_data{$f}, $new_data{$f}, "$f is updated";
}
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

# it should throw error b/c virtual can NOT update
$t = $t->send_ok({
        json => {
            set_settings => 1,
            %new_data
        }})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'PermissionDenied';

## VR with no residence, try set residence = 'jp' should fail
$test_client_vr->residence('');
$test_client_vr->save;

$t = $t->send_ok({
        json => {
            set_settings => 1,
            residence    => 'jp',
        }})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'PermissionDenied';

## JP client update setting should fail
my $client_jp = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'JP',
});
$client_jp->residence('jp');
$client_jp->save;

$token = BOM::Platform::SessionCookie->new(
    loginid => $client_jp->loginid,
    email   => $client_jp->email,
)->token;

# authorize ok
$t = $t->send_ok({json => {authorize => $token}})->message_ok;

$t = $t->send_ok({
        json => {
            "set_settings"   => 1,
            "address_line_1" => "Test Address Line 1",
            "address_line_2" => "Test Address Line 2",
            "phone"          => "1234567890"
        }})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'PermissionDenied';

$t->finish_ok;
done_testing();
