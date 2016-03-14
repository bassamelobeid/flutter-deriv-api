use strict;
use warnings;
use Test::More;
use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;

my $m            = BOM::Database::Model::OAuth->new;
my $test_loginid = 'CR10002';
my $test_user_id = 999;

## clear
$m->dbh->do("DELETE FROM oauth.access_token");
$m->dbh->do("DELETE FROM oauth.user_scope_confirm");
$m->dbh->do("DELETE FROM oauth.apps WHERE id <> 'binarycom'");

my $app1 = $m->create_app({
    name         => 'App 1',
    scopes       => ['read', 'payments', 'trade', 'admin'],
    homepage     => 'http://www.example.com/',
    github       => 'https://github.com/binary-com/binary-static',
    user_id      => $test_user_id,
    redirect_uri => 'https://www.example.com',
});
my $test_appid = $app1->{app_id};

## it's in test db
my $app = $m->verify_app($test_appid);
is $app->{id}, $test_appid;

$m->dbh->do("DELETE FROM oauth.user_scope_confirm");    # clear
my $is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid);
is $is_confirmed, 0, 'not confirmed';

ok $m->confirm_scope($test_appid, $test_loginid), 'confirm scope';
$is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid);
is $is_confirmed, 1, 'confirmed after confirm_scope';

my ($access_token) = $m->store_access_token_only($test_appid, $test_loginid);
ok $access_token;
is $m->get_loginid_by_access_token($access_token), $test_loginid, 'get_loginid_by_access_token';

my @scopes = $m->get_scopes_by_access_token($access_token);
is_deeply([sort @scopes], ['admin', 'payments', 'read', 'trade'], 'scopes are right');

### get app_register/app_list/app_get
my $get_app = $m->get_app($test_user_id, $app1->{app_id});
is_deeply($app1, $get_app, 'same on get');

my $app2 = $m->create_app({
    name         => 'App 2',
    scopes       => ['read', 'admin'],
    user_id      => $test_user_id,
    redirect_uri => 'https://www.example2.com',
});
my $get_apps = $m->get_apps_by_user_id($test_user_id);
is_deeply($get_apps, [$app1, $app2], 'get_apps_by_user_id ok');

my $delete_st = $m->delete_app($test_user_id, $app2->{app_id});
ok $delete_st;
$get_apps = $m->get_apps_by_user_id($test_user_id);
is_deeply($get_apps, [$app1], 'delete app ok');

## delete again will just return 0
$delete_st = $m->delete_app($test_user_id, $app2->{app_id});
ok !$delete_st, 'was deleted';

done_testing();
