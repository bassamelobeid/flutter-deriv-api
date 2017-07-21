#!perl

use strict;
use warnings;
use Test::More;
use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;

my $m            = BOM::Database::Model::OAuth->new;
my $test_loginid = 'CR10002';
my $test_user_id = 999;

## clear
$m->dbh->do("DELETE FROM oauth.access_token");
$m->dbh->do("DELETE FROM oauth.user_scope_confirm");
$m->dbh->do("DELETE FROM oauth.apps");

my $app1 = $m->create_app({
    name             => 'App 1',
    scopes           => ['read', 'payments', 'trade'],
    homepage         => 'http://www.example.com/',
    github           => 'https://github.com/binary-com/binary-static',
    user_id          => $test_user_id,
    redirect_uri     => 'https://www.example.com',
    verification_uri => 'https://www.example.com/verify',
});
my $test_appid = $app1->{app_id};
is $app1->{homepage},         'http://www.example.com/',        'homepage is correct';
is $app1->{verification_uri}, 'https://www.example.com/verify', 'verification_uri is correct';

my $verification_uri = $m->get_verification_uri_by_app_id($test_appid);
is $app1->{verification_uri}, $verification_uri, 'get_verification_uri_by_app_id';

## it's in test db
my $app = $m->verify_app($test_appid);
is $app->{id}, $test_appid;

my $is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid);
is $is_confirmed, 0, 'not confirmed';

ok $m->confirm_scope($test_appid, $test_loginid), 'confirm scope';
$is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid);
is $is_confirmed, 1, 'confirmed after confirm_scope';

my ($access_token, $exp) = $m->store_access_token_only($test_appid, $test_loginid);
ok $access_token;
my ($result_loginid, $t, $ua_fp) = @{$m->get_token_details($access_token)}{qw/loginid creation_time ua_fingerprint/};
is $result_loginid, $test_loginid, 'got correct loginid from token';
is $m->get_app_id_by_token($access_token), $test_appid, 'get_app_id_by_token';

my @scopes = $m->get_scopes_by_access_token($access_token);
is_deeply([sort @scopes], ['payments', 'read', 'trade'], 'scopes are right');

## test update_app
$app1 = $m->update_app(
    $test_appid,
    {
        name             => 'App 1',
        scopes           => ['read', 'payments', 'trade'],
        redirect_uri     => 'https://www.example.com/callback',
        verification_uri => 'https://www.example.com/verify_updated',
        homepage         => 'http://www.example2.com/',
    });
is $app1->{redirect_uri},     'https://www.example.com/callback',       'redirect_uri is updated';
is $app1->{verification_uri}, 'https://www.example.com/verify_updated', 'verification_uri is updated';
is $app1->{homepage},         'http://www.example2.com/',               'homepage is updated';

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
is_deeply([sort @{$used_apps->[0]->{scopes}}], ['payments', 'read', 'trade'], 'scopes are right');
ok $used_apps->[0]->{last_used}, 'last_used ok';

ok $m->revoke_app($test_appid, $test_loginid);
$is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid);
is $is_confirmed, 0, 'not confirmed after revoke';
($result_loginid, $t, $ua_fp) = @{$m->get_token_details($access_token)}{qw/loginid creation_time ua_fingerprint/};
is $result_loginid, undef, 'token is not valid anymore';

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
            ($result_loginid, $t, $ua_fp) = @{$m->get_token_details($access_token)}{qw/loginid creation_time ua_fingerprint/};
            is $result_loginid, $loginid, 'correct loginid from token details';
            is $m->get_app_id_by_token($access_token), $app_id, 'get_app_id_by_token';
        }
    }

    # setup BO app, id = 4
    my $sql = 'INSERT INTO oauth.apps (id, name, binary_user_id, redirect_uri, scopes) VALUES (?,?,?,?,?)';
    $m->dbh->do($sql, undef, 4, 'Binary.com backoffice', 1, 'https://www.binary.com/en/logged_inws.html', '{read}');

    foreach my $loginid (@loginids) {
        my @cnt = $m->dbh->selectrow_array("SELECT count(*) FROM oauth.access_token WHERE loginid = ?", undef, $loginid);
        is $cnt[0], 3, "access tokens [$loginid]";

        is $m->has_other_login_sessions($loginid), 1, "$loginid has other oauth token";

        is $m->revoke_tokens_by_loginid_app($loginid, $app1->{app_id}), 1, 'revoke_tokens_by_loginid_app';
        @cnt = $m->dbh->selectrow_array("SELECT count(*) FROM oauth.access_token WHERE loginid = ?", undef, $loginid);
        is $cnt[0], 2, "access tokens [$loginid]";

        is $m->revoke_tokens_by_loginid($loginid), 1, 'revoke_tokens_by_loginid';
        @cnt = $m->dbh->selectrow_array("SELECT count(*) FROM oauth.access_token WHERE loginid = ?", undef, $loginid);
        is $cnt[0], 0, "revoked access tokens [$loginid]";

        isnt $m->has_other_login_sessions($loginid), 1, "$loginid has NO oauth token";

        # Backoffice impersonate app id = 4, exclude in ->has_other_login_sessions
        my ($bo_token) = $m->store_access_token_only(4, $loginid);
        @cnt = $m->dbh->selectrow_array("SELECT count(*) FROM oauth.access_token WHERE loginid = ?", undef, $loginid);
        is $cnt[0], 1, "BO access tokens [$loginid]";
        isnt $m->has_other_login_sessions($loginid), 1, "$loginid has NO oauth token, beside for BO impersonate";
    }
};

subtest 'remove user confirm on scope changes' => sub {
    my $app1 = $m->create_app({
        name         => 'App 1 Change',
        scopes       => ['read', 'trade'],
        user_id      => $test_user_id,
        redirect_uri => 'https://www.example.com',
    });
    my $test_appid = $app1->{app_id};

    my $is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid);
    is $is_confirmed, 0, 'not confirmed';

    ok $m->confirm_scope($test_appid, $test_loginid), 'confirm scope';
    $is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid);
    is $is_confirmed, 1, 'confirmed after confirm_scope';

    ## update app without scope change
    $app1 = $m->update_app(
        $test_appid,
        {
            name         => 'App 1 Change 2',
            scopes       => ['read', 'trade'],
            redirect_uri => 'https://www.example.com/callback',
        });
    $is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid);
    is $is_confirmed, 1, 'is still confirmed if scope is not changed';

    $app1 = $m->update_app(
        $test_appid,
        {
            name         => 'App 1 Change 2',
            scopes       => ['read', 'trade', 'admin'],
            redirect_uri => 'https://www.example.com/callback',
        });
    $is_confirmed = $m->is_scope_confirmed($test_appid, $test_loginid);
    is $is_confirmed, 0, 'is not confirmed if scope is changed';

    my ($access_token) = $m->store_access_token_only($test_appid, $test_loginid);
    my @scopes = $m->get_scopes_by_access_token($access_token);
    is_deeply([sort @scopes], ['admin', 'read', 'trade'], 'scopes are updated');
};

done_testing();
