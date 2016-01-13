use strict;
use warnings;
use Test::More;
use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;

my $m             = BOM::Database::Model::OAuth->new;
my $test_loginid  = 'CR10002';
my $test_clientid = 'binarycom';

## it's in test db
my $client = $m->verify_client($test_clientid);
is $client->{id}, $test_clientid;

$m->dbh->do("DELETE FROM oauth.user_scope_confirm");    # clear
my $is_confirmed = $m->is_scope_confirmed($test_clientid, $test_loginid, 'trade');
is $is_confirmed, 0, 'not confirmed';

ok $m->confirm_scope($test_clientid, $test_loginid, 'trade'), 'confirm scope';
$is_confirmed = $m->is_scope_confirmed($test_clientid, $test_loginid, 'trade');
is $is_confirmed, 1, 'confirmed after confirm_scope';

# create then verify
my $code = $m->store_auth_code($test_clientid, $test_loginid, 'trade');
ok $code, 'code created';

my $loginid = $m->verify_auth_code($test_clientid, $code);
is $loginid, $test_loginid, 'verify ok';

my @scope_ids = $m->get_scope_ids_by_auth_code($code);
is_deeply(\@scope_ids, [1], 'scope_ids by auth_code');

# you can't re-use the code
ok(!$m->verify_auth_code($test_clientid, $code), 'can not re-use');

## try access_token
my ($access_token, $refresh_token) = $m->store_access_token($test_clientid, $test_loginid, 1);
ok $access_token;
ok $refresh_token;
ok $access_token ne $refresh_token;
is $m->get_loginid_by_access_token($access_token), $test_loginid, 'get_loginid_by_access_token';

$loginid = $m->verify_refresh_token($test_clientid, $refresh_token);
is $loginid, $test_loginid, 'refresh_token ok';

@scope_ids = $m->get_scope_ids_by_refresh_token($refresh_token);
is_deeply(\@scope_ids, [1], 'scope_ids by refresh_token');

ok(!$m->verify_refresh_token($test_clientid, $refresh_token), 'can not re-use');
ok(!$m->verify_refresh_token($test_clientid, $access_token),  'access_token is not for refresh');

### get app_register/app_list/app_get
my $test_user_id = 999;
$m->dbh->do("DELETE FROM oauth.clients WHERE binary_user_id = $test_user_id");    # clear

my $app1 = $m->create_client({
    name     => 'App 1',
    homepage => 'http://www.example.com/',
    github   => 'https://github.com/binary-com/binary-static',
    user_id  => $test_user_id,
});
my $get_app = $m->get_client($test_user_id, $app1->{client_id});
is_deeply($app1, $get_app, 'same on get');

my $app2 = $m->create_client({
    name    => 'App 2',
    user_id => $test_user_id,
});
my $get_apps = $m->get_clients_by_user_id($test_user_id);
is_deeply($get_apps, [$app1, $app2], 'get_clients_by_user_id ok');

done_testing();
