use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use Test::MockModule;

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

use await;

my $t = build_wsapi_test();

# prepare client
my $email  = 'test-binary@binary.com';
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

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

my $authorize = $t->await::authorize({authorize => $token});

ok !$authorize->{error}, "authorised";

my $i         = 0;
my $limit_hit = 0;
while (!$limit_hit && $i < 500) {
    my $msg = $t->await::portfolio({portfolio => 1});
    $limit_hit = ($msg->{error}->{code} // '?') eq 'RateLimit';
    $i++;
}
BAIL_OUT("cannot hit limit after $i attempts, no sense test further")
    if ($i == 500);
pass "rate limit reached";

my $logout = $t->await::logout({logout => 1});
is $logout->{logout}, 1;

($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
$authorize = $t->await::authorize({authorize => $token});

ok !$authorize->{error}, "re-authorised";

my $msg = $t->await::portfolio({portfolio => 1});
is $msg->{error}->{code}, 'RateLimit', "rate limitations are persisted between invocations";

done_testing;
