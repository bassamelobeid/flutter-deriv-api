use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_client/;
use Test::MockModule;

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::Password;
use BOM::Platform::User;
use Client::Account;

use await;

my $t = build_wsapi_test({language => 'EN'});

my $email    = 'abc@binary.com';
my $password = 'jskjd8292922';
my $hash_pwd = BOM::Platform::Password::hashpw($password);

my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client_vr->set_default_account('USD');
$client_vr->email($email);
$client_vr->save;
$client_cr->set_default_account('USD');
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

# non-virtual account is not allowed
my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $cr_1);

my $authorize = $t->await::authorize({authorize => $token});
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $cr_1;

my ($res, $call_params) = call_mocked_client($t, {topup_virtual => 1});
is $call_params->{language}, 'EN';
ok exists $call_params->{token};
is $res->{msg_type}, 'topup_virtual';
ok $res->{error}->{message} =~ /virtual accounts only/, 'virtual accounts only';

# virtual is ok
$client_vr = Client::Account->new({loginid => $client_vr->loginid});
my $old_balance = $client_vr->default_account->balance;

($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_1);

$authorize = $t->await::authorize({authorize => $token});
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $vr_1;

$res = $t->await::topup_virtual({topup_virtual => 1});
my $topup_amount = $res->{topup_virtual}->{amount};
ok $topup_amount, 'topup ok';

$client_vr = Client::Account->new({loginid => $client_vr->loginid});
ok $old_balance + $topup_amount == $client_vr->default_account->balance, 'balance is right';

$res = $t->await::topup_virtual({topup_virtual => 1});
ok $res->{error}->{message} =~ /Your balance is higher than the permitted amount/, 'Your balance is higher than the permitted amount';

$client_vr = Client::Account->new({loginid => $client_vr->loginid});
ok $old_balance + $topup_amount == $client_vr->default_account->balance, 'balance stays same';

$t->finish_ok;

done_testing();
