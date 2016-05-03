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
is $m->get_app_id_by_token($access_token), $test_appid, 'get_app_id_by_token';

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

## test get_used_apps_by_loginid and revoke
my $used_apps = $m->get_used_apps_by_loginid($test_loginid);
is scalar(@{$used_apps}), 1;
is $used_apps->[0]->{app_id}, $test_appid, 'app_id 1';
is_deeply([sort @{$used_apps->[0]->{scopes}}], ['admin', 'payments', 'read', 'trade'], 'scopes are right');
ok $used_apps->[0]->{last_used}, 'last_used ok';

ok $m->revoke_app($test_appid, $test_loginid);
$is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid);
is $is_confirmed, 0, 'not confirmed after revoke';
is $m->get_loginid_by_access_token($access_token), undef, 'token is not valid anymore';

## delete again will just return 0
$delete_st = $m->delete_app($test_user_id, $app2->{app_id});
ok !$delete_st, 'was deleted';

$delete_st = $m->delete_app($test_user_id, $app1->{app_id});

subtest 'revoke tokens by loginid and app_id' => sub {
    my $app1 = $m->create_app({
        name         => 'App 1',
        scopes       => ['read', 'admin'],
        user_id      => $test_user_id,
        redirect_uri => 'https://www.example.com',
    });
    my $app2 = $m->create_app({
        name         => 'App 2',
        scopes       => ['read', 'admin'],
        user_id      => $test_user_id,
        redirect_uri => 'https://www.example2.com',
    });
    my $app3 = $m->create_app({
        name         => 'App 3',
        scopes       => ['read', 'admin'],
        user_id      => $test_user_id,
        redirect_uri => 'https://www.example3.com',
    });
    my $get_apps = $m->get_apps_by_user_id($test_user_id);
    is_deeply($get_apps, [$app1, $app2, $app3], 'get_apps_by_user_id ok');

    my @app_ids = ($app1->{app_id}, $app2->{app_id}, $app3->{app_id});
    my @loginids = ('CR1234', 'VRTC1234');

    foreach my $loginid (@loginids) {
        foreach my $app_id (@app_ids) {
            ok $m->confirm_scope($app_id, $loginid), 'confirm scope';
            my $is_confirmed = $m->is_scope_confirmed($app_id, $loginid);
            is $is_confirmed, 1, 'confirmed after confirm_scope';

            my ($access_token) = $m->store_access_token_only($app_id, $loginid);
            ok $access_token;
            is $m->get_loginid_by_access_token($access_token), $loginid, 'get_loginid_by_access_token';
            is $m->get_app_id_by_token($access_token), $app_id, 'get_app_id_by_token';
        }
    }

    foreach my $loginid (@loginids) {
        my @cnt = $m->dbh->selectrow_array("SELECT count(*) FROM oauth.access_token WHERE loginid = ?", undef, $loginid);
        is $cnt[0], 3, "access tokens [$loginid]";

        is $m->revoke_tokens_by_loginid_app($loginid, $app1->{app_id}), 1, 'revoke_tokens_by_loginid_app';
        @cnt = $m->dbh->selectrow_array("SELECT count(*) FROM oauth.access_token WHERE loginid = ?", undef, $loginid);
        is $cnt[0], 2, "access tokens [$loginid]";

        is $m->revoke_tokens_by_loginid($loginid), 1, 'revoke_tokens_by_loginid';
        @cnt = $m->dbh->selectrow_array("SELECT count(*) FROM oauth.access_token WHERE loginid = ?", undef, $loginid);
        is $cnt[0], 0, "revoked access tokens [$loginid]";
    }
};

done_testing();
