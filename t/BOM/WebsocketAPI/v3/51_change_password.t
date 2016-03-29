use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::SessionCookie;
use BOM::Database::Model::AccessToken;
use BOM::System::Password;
use BOM::Platform::User;
use BOM::Platform::Client;

my $t = build_mojo_test();

my $email    = 'abc@binary.com';
my $password = 'jskjP8292922';
my $hash_pwd = BOM::System::Password::hashpw($password);

my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client_vr->email($email);
$client_vr->save;
$client_cr->email($email);
$client_cr->save;
my $vr_1 = $client_vr->loginid;
my $cr_1 = $client_cr->loginid;

my $user = BOM::Platform::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->save;

$user->add_loginid({loginid => $vr_1});
$user->add_loginid({loginid => $cr_1});
$user->save;

my $status = $user->login(password => $password);
is $status->{success}, 1, 'login with correct password OK';
$status = $user->login(password => 'mRX1E3Mi00oS8LG');
ok !$status->{success}, 'Bad password; cannot login';

my $token = BOM::Platform::SessionCookie->new(
    loginid => $vr_1,
    email   => $email,
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $vr_1;

my $new_password = 'jskjD8292923';
my $new_hash_pwd = BOM::System::Password::hashpw($new_password);

# change password wrongly
$t = $t->send_ok({
        json => {
            change_password => 1,
            old_password    => 'mRX1E3Mi00oS8LG',
            new_password    => $new_password
        }})->message_ok;
my $change_password = decode_json($t->message->[1]);
is $change_password->{error}->{code}, 'PasswordError';
ok $change_password->{error}->{message} =~ /Old password is wrong/;
test_schema('change_password', $change_password);

$t = $t->send_ok({
        json => {
            change_password => 1,
            old_password    => $password,
            new_password    => 'a'
        }})->message_ok;
$change_password = decode_json($t->message->[1]);
is $change_password->{error}->{code}, 'InputValidationFailed';
test_schema('change_password', $change_password);

$t = $t->send_ok({
        json => {
            change_password => 1,
            old_password    => $password,
            new_password    => $password
        }})->message_ok;
$change_password = decode_json($t->message->[1]);
is $change_password->{error}->{code}, 'PasswordError';
ok $change_password->{error}->{message} =~ /New password is same as old password/;
test_schema('change_password', $change_password);

# change password
$t = $t->send_ok({
        json => {
            change_password => 1,
            old_password    => $password,
            new_password    => $new_password
        }})->message_ok;
$change_password = decode_json($t->message->[1]);
ok($change_password->{change_password});
is($change_password->{change_password}, 1);
test_schema('change_password', $change_password);

# refetch user
$user = BOM::Platform::User->new({
    email => $email,
});
$status = $user->login(password => $password);
ok !$status->{success}, 'old password; cannot login';
$status = $user->login(password => $new_password);
is $status->{success}, 1, 'login with new password OK';

## client passwd should be changed as well
foreach my $client ($user->clients) {
    is $client->password, $user->password;
}

## for api token, it's not allowed to change password
$token = BOM::Database::Model::AccessToken->new->create_token($vr_1, 'Test Token', 'read', 'admin');
$t = $t->send_ok({json => {authorize => $token}})->message_ok;
$authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $vr_1;
$t = $t->send_ok({
        json => {
            change_password => 1,
            old_password    => $new_password,
            new_password    => 'abc123456'
        }})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'PermissionDenied', 'got PermissionDenied for api token';

$t->finish_ok;

done_testing();
