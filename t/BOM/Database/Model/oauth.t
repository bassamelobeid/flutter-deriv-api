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

# create then verify
my $code = $m->store_auth_code($test_clientid, $test_loginid);
ok $code, 'code created';

my $loginid = $m->verify_auth_code($test_clientid, $code);
is $loginid, $test_loginid, 'verify ok';

# you can't re-use the code
ok(!$m->verify_auth_code($test_clientid, $code), 'can not re-use');

## try access_token
my ($access_token, $refresh_token) = $m->store_access_token($test_clientid, $test_loginid);
ok $access_token;
ok $refresh_token;
ok $access_token ne $refresh_token;
diag $access_token;
is $m->get_loginid_by_access_token($access_token), $test_loginid, 'get_loginid_by_access_token';

$loginid = $m->verify_refresh_token($test_clientid, $refresh_token);
is $loginid, $test_loginid, 'refresh_token ok';

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
