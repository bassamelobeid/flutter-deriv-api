use strict;
use warnings;
use Test::More;
use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;

my $m             = BOM::Database::Model::OAuth->new;
my $test_loginid  = 'CR10002';
my $test_appid    = 'binarycom';

## clear
$m->dbh->do("DELETE FROM oauth.app_redirect_uri WHERE app_id <> '$test_appid'");
$m->dbh->do("DELETE FROM oauth.apps WHERE id <> '$test_appid'");

## it's in test db
my $app = $m->verify_app($test_appid);
is $app->{id}, $test_appid;

ok $m->verify_app_redirect_uri($test_appid, 'http://localhost'), 'verify_app_redirect_uri localhost';
ok $m->verify_app_redirect_uri($test_appid, 'http://localhost/'), 'verify_app_redirect_uri localhost/';
ok $m->verify_app_redirect_uri($test_appid, 'https://www.binary.com/'), 'verify_app_redirect_uri binary.com/';
ok ! $m->verify_app_redirect_uri($test_appid, 'https://www.example.com/'), 'verify_app_redirect_uri example.com/';

$m->dbh->do("DELETE FROM oauth.user_scope_confirm");    # clear
my $is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid, 'user', 'trade');
is $is_confirmed, 0, 'not confirmed';

ok $m->confirm_scope($test_appid, $test_loginid, 'user', 'trade'), 'confirm scope';
$is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid, 'user', 'trade');
is $is_confirmed, 1, 'confirmed after confirm_scope';

# create then verify
my $code = $m->store_auth_code($test_appid, $test_loginid, 'user', 'trade');
ok $code, 'code created';

my $loginid = $m->verify_auth_code($test_appid, $code);
is $loginid, $test_loginid, 'verify ok';

my @scope_ids = $m->get_scope_ids_by_auth_code($code);
is_deeply([sort @scope_ids], [1, 2], 'scope_ids by auth_code');

# you can't re-use the code
ok(!$m->verify_auth_code($test_appid, $code), 'can not re-use');

## try access_token
my ($access_token, $refresh_token) = $m->store_access_token($test_appid, $test_loginid, @scope_ids);
ok $access_token;
ok $refresh_token;
ok $access_token ne $refresh_token;
is $m->get_loginid_by_access_token($access_token), $test_loginid, 'get_loginid_by_access_token';

$loginid = $m->verify_refresh_token($test_appid, $refresh_token);
is $loginid, $test_loginid, 'refresh_token ok';

my @scope_ids_rf = $m->get_scope_ids_by_refresh_token($refresh_token);
is_deeply(\@scope_ids, \@scope_ids_rf, 'scope_ids by refresh_token is same as auth_code');
my @scopes = $m->get_scopes_by_access_token($access_token);
is_deeply([sort @scopes], ['trade', 'user'], 'correct scope by access_token');

ok(!$m->verify_refresh_token($test_appid, $refresh_token), 'can not re-use');
ok(!$m->verify_refresh_token($test_appid, $access_token),  'access_token is not for refresh');

### get app_register/app_list/app_get
my $test_user_id = 999;
my $app1 = $m->create_app({
    name     => 'App 1',
    homepage => 'http://www.example.com/',
    github   => 'https://github.com/binary-com/binary-static',
    user_id  => $test_user_id,
    redirect_uri => ['https://www.example.com'],
});
my $get_app = $m->get_app($test_user_id, $app1->{app_id});
is_deeply($app1, $get_app, 'same on get');

ok $m->verify_app_redirect_uri($app1->{app_id}, 'https://www.example.com/'), 'verify_app_redirect_uri example.com/';
ok ! $m->verify_app_redirect_uri($app1->{app_id}, 'https://www.example2.com/'), 'verify_app_redirect_uri example2.com/';

my $app2 = $m->create_app({
    name    => 'App 2',
    user_id => $test_user_id,
    redirect_uri => ['https://www.example2.com'],
});
my $get_apps = $m->get_apps_by_user_id($test_user_id);
is_deeply($get_apps, [$app1, $app2], 'get_apps_by_user_id ok');

ok $m->verify_app_redirect_uri($app2->{app_id}, 'https://www.example2.com/'), 'verify_app_redirect_uri example2.com/';
ok ! $m->verify_app_redirect_uri($app2->{app_id}, 'https://www.example.com/'), 'verify_app_redirect_uri example.com/';

$m->delete_app($test_user_id, $app2->{app_id});
$get_apps = $m->get_apps_by_user_id($test_user_id);
is_deeply($get_apps, [$app1], 'delete app ok');

done_testing();
