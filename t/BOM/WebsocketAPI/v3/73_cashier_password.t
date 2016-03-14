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
use BOM::System::Password;
use BOM::Platform::User;
use BOM::Platform::Client;

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::Platform::Client');
$client_mocked->mock('add_note', sub { return 1 });
my $email_mocked = Test::MockModule->new('BOM::Platform::Email');
$email_mocked->mock('send_email', sub { return 1 });

my $t = build_mojo_test();

my $email     = 'abc@binary.com';
my $password  = 'jSkjd8292922';
my $hash_pwd  = BOM::System::Password::hashpw($password);
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client_cr->email($email);
$client_cr->save;
my $cr_1 = $client_cr->loginid;
my $user = BOM::Platform::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->save;
$user->add_loginid({loginid => $cr_1});
$user->save;

my $token = BOM::Platform::SessionCookie->new(
    loginid => $cr_1,
    email   => $email,
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $cr_1;

# lock cashier
$t = $t->send_ok({json => {cashier_password => 1}})->message_ok;
my $res = decode_json($t->message->[1]);
ok $res->{cashier_password} == 0, 'password was not set';
test_schema('cashier_password', $res);

## use same password as login is not ok
$t = $t->send_ok({
        json => {
            cashier_password => 1,
            lock_password    => $password
        }})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{error}->{message} =~ /Please use a different password than your login password/, 'Please use a different password than your login password';

$password = 'Uplow2134445';
$t        = $t->send_ok({
        json => {
            cashier_password => 1,
            lock_password    => $password
        }})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{cashier_password};
test_schema('cashier_password', $res);

$t = $t->send_ok({json => {cashier_password => 1}})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{cashier_password} == 1, 'password was set';
test_schema('cashier_password', $res);

$t = $t->send_ok({
        json => {
            cashier_password => 1,
            lock_password    => rand()}})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{error}->{message} =~ /Your cashier was locked/, 'Your cashier was locked';

$client_cr = BOM::Platform::Client->new({loginid => $client_cr->loginid});
ok length $client_cr->cashier_setting_password, 'cashier_setting_password is set';

# unlock
$t = $t->send_ok({
        json => {
            cashier_password => 1,
            unlock_password  => $password . '1'
        }})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{error}->{message} =~ /you have entered an incorrect cashier password/, 'you have entered an incorrect cashier password';

$t = $t->send_ok({
        json => {
            cashier_password => 1,
            unlock_password  => $password
        }})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{cashier_password} == 0;
test_schema('cashier_password', $res);

$t = $t->send_ok({json => {cashier_password => 1}})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{cashier_password} == 0, 'password was clear';
test_schema('cashier_password', $res);

$client_cr = BOM::Platform::Client->new({loginid => $client_cr->loginid});
ok(length($client_cr->cashier_setting_password) == 0, 'cashier_setting_password is clear');

$t = $t->send_ok({
        json => {
            cashier_password => 1,
            unlock_password  => $password
        }})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{error}->{message} =~ /Your cashier was not locked/, 'Your cashier was not locked';

$t->finish_ok;

done_testing();
