use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

use BOM::Database::Model::OAuth;
use BOM::Database::Model::AccessToken;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::User::Password;
use BOM::User;
use BOM::User::Client;

use await;

my $t = build_wsapi_test();

my $email    = 'abc@binary.com';
my $password = 'jskjP8292922';
my $hash_pwd = BOM::User::Password::hashpw($password);

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

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

$user->add_client($client_vr);
$user->add_client($client_cr);

my $status = $user->login(password => $password);
is $status->{success}, 1, 'login with correct password OK';
$status = $user->login(password => 'mRX1E3Mi00oS8LG');
ok !$status->{success}, 'Bad password; cannot login';

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_1);

my $authorize = $t->await::authorize({authorize => $token});
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $vr_1;

my $new_password = 'jskjD8292923';
my $new_hash_pwd = BOM::User::Password::hashpw($new_password);

# change password wrongly
my $change_password = $t->await::change_password({
    change_password => 1,
    old_password    => 'mRX1E3Mi00oS8LG',
    new_password    => $new_password
});
is $change_password->{error}->{code}, 'PasswordError';
ok $change_password->{error}->{message} =~ /Provided password is incorrect/;
test_schema('change_password', $change_password);

$change_password = $t->await::change_password({
    change_password => 1,
    old_password    => $password,
    new_password    => 'a'
});
is $change_password->{error}->{code}, 'InputValidationFailed';
test_schema('change_password', $change_password);

$change_password = $t->await::change_password({
    change_password => 1,
    old_password    => $password,
    new_password    => $password
});
is $change_password->{error}->{code}, 'PasswordError';
ok $change_password->{error}->{message} =~ /Current password and new password cannot be the same/;
test_schema('change_password', $change_password);

# change password
$change_password = $t->await::change_password({
    change_password => 1,
    old_password    => $password,
    new_password    => $new_password
});
ok($change_password->{change_password});
is($change_password->{change_password}, 1);
test_schema('change_password', $change_password);

# refetch user
$user = BOM::User->new(
    email => $email,
);
$status = $user->login(password => $password);
ok !$status->{success}, 'old password; cannot login';
$status = $user->login(password => $new_password);
is $status->{success}, 1, 'login with new password OK';

## client passwd should be changed as well
foreach my $client ($user->clients) {
    is $client->password, $user->{password};
}

## for api token, it's not allowed to change password
$token = BOM::Database::Model::AccessToken->new->create_token($vr_1, 'Test Token', ['read', 'admin']);
$authorize = $t->await::authorize({authorize => $token});
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $vr_1;
my $res = $t->await::change_password({
    change_password => 1,
    old_password    => $new_password,
    new_password    => 'abc123456'
});
is $res->{error}->{code}, 'PermissionDenied', 'got PermissionDenied for api token';

$t->finish_ok;

done_testing();
