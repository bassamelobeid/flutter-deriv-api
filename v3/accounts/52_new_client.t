use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::Password;
use BOM::User;
use Client::Account;

use await;

my $t = build_wsapi_test();

my $email    = 'abc@binary.com';
my $password = 'jskjd8292922';
my $hash_pwd = BOM::Platform::Password::hashpw($password);

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
$user->save;

$user->add_loginid({loginid => $vr_1});
$user->add_loginid({loginid => $cr_1});
$user->save;

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_1);

my $authorize = $t->await::authorize({authorize => $token});
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $vr_1;

## test statement
my $statement = $t->await::statement({
    statement => 1,
    limit     => 1
});
ok($statement->{statement});
is($statement->{statement}->{count}, 0);
is_deeply $statement->{statement}->{transactions}, [];
test_schema('statement', $statement);

## test profit table
my $profit_table = $t->await::profit_table({
    profit_table => 1,
    limit        => 1
});
ok($profit_table->{profit_table});
is($profit_table->{profit_table}->{count}, 0);
is_deeply $profit_table->{profit_table}->{transactions}, [];
test_schema('profit_table', $profit_table);

## test disabled
$client_vr->set_status('disabled', 'test.t', "just for test");
$client_vr->save();
my $res = $t->await::profit_table({
    profit_table => 1,
    limit        => 1
});

is $res->{error}->{code}, 'DisabledClient', 'you can not call any authenticated api after disabled.';

$t->finish_ok;

done_testing();
