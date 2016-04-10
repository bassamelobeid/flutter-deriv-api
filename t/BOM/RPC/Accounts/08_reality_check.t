use strict;
use warnings;

use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use utf8;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::User;
use BOM::Platform::SessionCookie;
use BOM::System::Password;

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

my $email          = 'r@binary.com';
my $password       = 'jskjd8292922';
my $hash_pwd       = BOM::System::Password::hashpw($password);
my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_vr->email($email);
$test_client_vr->save;

my $test_client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MLT',
});
$test_client_mlt->email($email);
$test_client_mlt->save;

my $test_client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
$test_client_mf->email($email);
$test_client_mf->save;

my $user = BOM::Platform::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->save;
$user->add_loginid({loginid => $test_client_vr->loginid});
$user->add_loginid({loginid => $test_client_mlt->loginid});
$user->add_loginid({loginid => $test_client_mf->loginid});
$user->save;

my $method = 'reality_check';
$c->call_ok($method, {token => 12345})->has_error->error_message_is('The token is invalid.', 'check invalid token');

my $session = BOM::Platform::SessionCookie->new(
    loginid => $test_client_vr->loginid,
    email   => $email
);
my $token = $session->token;

my $result = $c->call_ok($method, {token => $token})->result;
is_deeply $result, {}, 'empty record for client that has no reality check';

$session = BOM::Platform::SessionCookie->new(
    loginid => $test_client_mlt->loginid,
    email   => $email
);
$token = $session->token;

$result = $c->call_ok($method, {token => $token})->result;
is $result->{start_time}, $session->{loginat}, 'Start time matches session login time';
is $result->{loginid}, $test_client_mlt->loginid, 'Contains correct loginid';
is $result->{open_contract_count}, 0, 'zero open contracts';

done_testing();
