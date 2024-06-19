use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

use BOM::User;
use BOM::Platform::Token::API;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw(create_client);
use BOM::Database::Model::OAuth;
use await;

my $t     = build_wsapi_test();
my $oauth = BOM::Database::Model::OAuth->new;

my $email = 'test-deriv@binary.com';
my $user  = BOM::User->create(
    email    => $email,
    password => '1234',
);
my $client_cr = create_client(
    'CR', undef,
    {
        email          => $email,
        binary_user_id => $user->id,
    });
my $loginid_cr = $client_cr->loginid;
my ($token_cr) = $oauth->store_access_token_only(1, $client_cr->loginid);
$client_cr->set_default_account('USD');

my $client_mf = create_client(
    'MF', undef,
    {
        email          => $email,
        binary_user_id => $user->id,
    });
my $loginid_mf = $client_mf->loginid;
my ($token_mf) = $oauth->store_access_token_only(1, $client_mf->loginid);
$client_mf->set_default_account('EUR');

# Create user and the CR and MF clients for the user
my $user_id = $client_cr->binary_user_id;

$user->add_client($client_cr);
$user->add_client($client_mf);

my $authorize = $t->await::authorize({authorize => $token_cr, tokens => [$token_mf]});

is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $loginid_cr;
is $authorize->{authorize}->{user_id}, $user_id;
test_schema('authorize', $authorize);

## it's ok after authorize
my $balance_cr = $t->await::balance({balance => 1});
ok($balance_cr->{balance});
is $balance_cr->{balance}{loginid}, $loginid_cr;
test_schema('balance', $balance_cr);

my $balance_mf = $t->await::balance({balance => 1, loginid => $loginid_mf});
ok($balance_mf->{balance});
is $balance_mf->{balance}{loginid}, $loginid_mf;
test_schema('balance', $balance_mf);

$t->finish_ok;

done_testing();
