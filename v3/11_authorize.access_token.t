use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

use BOM::Platform::User;
use BOM::Database::Model::AccessToken;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use await;

my $t = build_wsapi_test();

my $email  = 'test-binary' . rand(999) . '@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client->email($email);
$client->save;
$client->set_default_account('USD');

my $loginid = $client->loginid;
my $user    = BOM::Platform::User->create(
    email    => $email,
    password => '1234',
);
$user->add_loginid({loginid => $loginid});
$user->save;

my $token = BOM::Database::Model::AccessToken->new->create_token($loginid, 'Test', ['trade']);

my $authorize = $t->await::authorize({authorize => $token});
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $loginid;
test_schema('authorize', $authorize);

## it's ok after authorize
my $balance = $t->await::balance({balance => 1});
ok($balance->{balance});
test_schema('balance', $balance);

$t->finish_ok;

done_testing();
