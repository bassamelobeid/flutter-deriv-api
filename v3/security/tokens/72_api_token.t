use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use BOM::Test::Helper::Token qw(cleanup_redis_tokens);

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

use await;

# cleanup
cleanup_redis_tokens();
use BOM::Database::Model::AccessToken;
BOM::Database::Model::AccessToken->new->dbic->dbh->do("
    DELETE FROM $_
") foreach ('auth.access_token');

my $t = build_wsapi_test();

# prepare client
my $email  = 'test-binary@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client->email($email);
$client->save;

my $loginid = $client->loginid;
my $user    = BOM::User->create(
    email    => $email,
    password => '1234',
);
$user->add_client($client);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

$t->await::authorize({authorize => $token});

my $res = $t->await::api_token({api_token => 1});
ok($res->{api_token});
is_deeply($res->{api_token}->{tokens}, [], 'empty');
test_schema('api_token', $res);

# create new token
$res = $t->await::api_token({
        api_token        => 1,
        new_token        => 'Test Token',
        new_token_scopes => ['read']});
ok($res->{api_token});
ok $res->{api_token}->{new_token};
is scalar(@{$res->{api_token}->{tokens}}), 1, '1 token created';
my $test_token = $res->{api_token}->{tokens}->[0];
is $test_token->{display_name}, 'Test Token';
test_schema('api_token', $res);

# delete token
$res = $t->await::api_token({
        api_token    => 1,
        delete_token => $test_token->{token}});
ok($res->{api_token});
ok $res->{api_token}->{delete_token};
is_deeply($res->{api_token}->{tokens}, [], 'empty');
test_schema('api_token', $res);

## re-create
$res = $t->await::api_token({
    api_token => 1,
    new_token => '1'
});
ok $res->{error}->{message} =~ /alphanumeric with space and dash/, 'alphanumeric with space and dash';
test_schema('api_token', $res);

$res = $t->await::api_token({
    api_token => 1,
    new_token => '1' x 33
});
ok $res->{error}->{message} =~ /alphanumeric with space and dash/, 'alphanumeric with space and dash';
test_schema('api_token', $res);

$res = $t->await::api_token({
        api_token        => 1,
        new_token        => 'Test',
        new_token_scopes => ['read', 'admin']});
is scalar(@{$res->{api_token}->{tokens}}), 1, '1 token created';
$test_token = $res->{api_token}->{tokens}->[0];
is $test_token->{display_name}, 'Test';
ok !$test_token->{last_used}, 'last_used is null';
test_schema('api_token', $res);

$t->finish_ok;

# try with the new token
$t = build_wsapi_test();
$res = $t->await::authorize({authorize => $test_token->{token}});
is $res->{authorize}->{email}, $email;

$res = $t->await::api_token({api_token => 1});
ok($res->{api_token});
is scalar(@{$res->{api_token}->{tokens}}), 1, '1 token';
$test_token = $res->{api_token}->{tokens}->[0];
is $test_token->{display_name}, 'Test';
ok $test_token->{last_used},    'last_used is ok';
test_schema('api_token', $res);

$t->await::api_token({
        api_token    => 1,
        delete_token => $test_token->{token}});

$t->finish_ok;

done_testing();
