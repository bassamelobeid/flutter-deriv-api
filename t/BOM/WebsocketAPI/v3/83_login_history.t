use strict;
use warnings;
use Test::More;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::User;
use BOM::Platform::SessionCookie;
use BOM::System::Password;

my $email       = 'raunak@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::System::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email($email);
$test_client->save;

my $test_loginid = $test_client->loginid;
my $user         = BOM::Platform::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->save;
$user->add_loginid({loginid => $test_loginid});
$user->add_login_history({
    environment => 'dummy environment',
    successful  => 't',
    action      => 'logout',
});
$user->save;

my $t     = build_mojo_test();
my $token = BOM::Platform::SessionCookie->new(
    loginid => $test_loginid,
    email   => $email
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{authorize}->{email}, 'raunak@binary.com', 'Correct email for session cookie token';
test_schema('authorize', $res);

$t = $t->send_ok({json => {login_history => 1}})->message_ok;
$res = decode_json($t->message->[1]);
is scalar(@{$res->{login_history}}), 1, 'got correct number of login history records';
ok $res->{login_history}->[0]->{action},      'login history record has action key';
ok $res->{login_history}->[0]->{environment}, 'login history record has environment key';
ok $res->{login_history}->[0]->{time},        'login history record has time key';

# clear session token
$t = $t->send_ok({json => {logout => 1}})->message_ok;

done_testing();
