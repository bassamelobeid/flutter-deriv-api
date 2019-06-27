use strict;
use warnings;

no indirect;

use Test::More;
use Test::Deep;
use Test::Warnings qw(warnings);
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use TestHelper qw/create_test_user/;
use Test::MockModule;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::Database::Model::AccessToken;
use BOM::Test::RPC::Client;
use Test::Mojo;
use Email::Stuffer::TestLinks;

my $test_client  = create_test_user();
my $test_loginid = $test_client->loginid;

# cleanup
my $oauth = BOM::Database::Model::OAuth->new;
my $dbh   = $oauth->dbic->dbh;
$dbh->do("DELETE FROM oauth.access_token");
$dbh->do("DELETE FROM oauth.user_scope_confirm");
$dbh->do("DELETE FROM oauth.official_apps");
$dbh->do("DELETE FROM oauth.apps WHERE id <> 1");
BOM::Database::Model::AccessToken->new->remove_by_loginid($test_loginid);

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

my $mock_utility = Test::MockModule->new('BOM::RPC::v3::Utility');
# need to mock it as to access api token we need token beforehand
$mock_utility->mock('get_token_details', sub { return {loginid => $test_loginid} });

# create new api token
my $res = $c->call_ok(
    'api_token',
    {
        token => 'Abc123',
        args  => {
            api_token => 1,
            new_token => 'Sample1'
        },
    })->has_no_system_error->has_no_error->result;

is scalar(@{$res->{tokens}}), 1, "token created succesfully";
my $token = $res->{tokens}->[0]->{token};

$mock_utility->unmock('get_token_details');

my $app1 = $c->call_ok(
    'app_register',
    {
        token => $token,
        args  => {
            name             => 'App 1',
            scopes           => ['read', 'trade'],
            redirect_uri     => 'https://www.example.com/',
            verification_uri => 'https://www.example.com/verify',
            homepage         => 'https://www.homepage.com/',
        },
    })->has_no_system_error->has_no_error->result;
is_deeply([sort @{$app1->{scopes}}], ['read', 'trade'], 'scopes are right');
is $app1->{redirect_uri},     'https://www.example.com/',       'redirect_uri is right';
is $app1->{verification_uri}, 'https://www.example.com/verify', 'verification_uri is right';
is $app1->{homepage},         'https://www.homepage.com/',      'homepage is right';

$app1 = $c->call_ok(
    'app_update',
    {
        token => $token,
        args  => {
            app_update       => $app1->{app_id},
            name             => 'App 1',
            scopes           => ['read', 'trade', 'admin'],
            redirect_uri     => 'https://www.example.com/callback',
            verification_uri => 'https://www.example.com/verify_updated',
            homepage         => 'https://www.homepage2.com/'
        },
    })->has_no_system_error->has_no_error->result;
delete $app1->{stash};    # This will check against an ARRAY response which doesn't have the stash
is_deeply([sort @{$app1->{scopes}}], ['admin', 'read', 'trade'], 'scopes are updated');
is $app1->{redirect_uri},     'https://www.example.com/callback',       'redirect_uri is updated';
is $app1->{verification_uri}, 'https://www.example.com/verify_updated', 'redirect_uri is updated';
is $app1->{homepage},         'https://www.homepage2.com/',             'homepage is updated';

my $get_app = $c->call_ok(
    'app_get',
    {
        token => $token,
        args  => {
            app_get => $app1->{app_id},
        },
    })->has_no_system_error->has_no_error->result;
delete $get_app->{stash};    # This will check against an ARRAY response which doesn't have the stash
is_deeply($get_app, $app1, 'same on get');

$res = $c->call_ok(
    'app_register',
    {
        token => $token,
        args  => {
            name => 'App 1',
        },
    })->has_no_system_error->has_error->result;
ok $res->{error}->{message_to_client} =~ /The name is taken/, 'The name is taken';

my $app2 = $c->call_ok(
    'app_register',
    {
        token => $token,
        args  => {
            name                  => 'App 2',
            scopes                => ['read', 'admin'],
            redirect_uri          => 'https://www.example2.com/',
            app_markup_percentage => 2
        },
    })->has_no_system_error->has_no_error->result;
is $app2->{app_markup_percentage}, 2, 'app_markup_percentage is right';

$app2 = $c->call_ok(
    'app_update',
    {
        token => $token,
        args  => {
            app_update            => $app2->{app_id},
            name                  => 'App 2',
            scopes                => ['read', 'admin'],
            redirect_uri          => 'https://www.example2.com/',
            app_markup_percentage => 4
        },
    })->has_no_system_error->has_no_error->result;
delete $app2->{stash};    # This will check against an ARRAY response which doesn't have the stash
is $app2->{app_markup_percentage}, 4, 'app_markup_percentage is updated';

my $get_apps = $c->call_ok(
    'app_list',
    {
        token => $token,
        args  => {
            app_list => 1,
        },
    })->has_no_system_error->result;

$get_apps = [grep { $_->{app_id} ne '1' } @$get_apps];
is_deeply($get_apps, [$app1, $app2], 'list ok');

my $delete_st = $c->call_ok(
    'app_delete',
    {
        token => $token,
        args  => {
            app_delete => $app2->{app_id},
        },
    })->has_no_system_error->result;
ok $delete_st;

$get_apps = $c->call_ok(
    'app_list',
    {
        token => $token,
        args  => {
            app_list => 1,
        },
    })->has_no_system_error->result;
$get_apps = [grep { $_->{app_id} ne '1' } @$get_apps];
is_deeply($get_apps, [$app1], 'delete ok');

# delete again will return 0
$delete_st = $c->call_ok(
    'app_delete',
    {
        token => $token,
        args  => {
            app_delete => $app2->{app_id},
        },
    })->has_no_system_error->result;
ok !$delete_st, 'was deleted';

## for used and revoke
my $test_appid = $app1->{app_id};
$oauth = BOM::Database::Model::OAuth->new;    # re-connect db
ok $oauth->confirm_scope($test_appid, $test_loginid), 'confirm scope';
my ($access_token) = $oauth->store_access_token_only($test_appid, $test_loginid);
my $used_apps = $c->call_ok(
    'oauth_apps',
    {
        token => $access_token,
        args  => {
            oauth_apps => 1,
        },
    })->has_no_system_error->result;
is scalar(@{$used_apps}), 1;
is $used_apps->[0]->{app_id}, $test_appid, 'app_id 1';
is_deeply([sort @{$used_apps->[0]->{scopes}}], ['admin', 'read', 'trade'], 'scopes are right');
ok $used_apps->[0]->{last_used}, 'last_used ok';

$oauth = BOM::Database::Model::OAuth->new;    # re-connect db
my $is_confirmed = $oauth->is_scope_confirmed($test_appid, $test_loginid);
is $is_confirmed, 1, 'was confirmed';

# revoke app
$c->call_ok(
    'oauth_apps',
    {
        token => $access_token,
        args  => {
            oauth_apps => 1,
        },
    })->has_no_system_error;

$oauth = BOM::Database::Model::OAuth->new;                                # re-connect db
$is_confirmed = $oauth->is_scope_confirmed($test_appid, $test_loginid);
is $is_confirmed, 1, 'still confirmed';

$c->call_ok(
    'revoke_oauth_app',
    {
        token => $access_token,
        args  => {
            revoke_oauth_app => $test_appid,
        },
    })->has_no_system_error;

$oauth = BOM::Database::Model::OAuth->new;                                # re-connect db
$is_confirmed = $oauth->is_scope_confirmed($test_appid, $test_loginid);
is $is_confirmed, 0, 'not confirmed after revoke';

## the access_token is not working after revoke
$used_apps = $c->call_ok(
    'oauth_apps',
    {
        token => $access_token,
        args  => {
            oauth_apps => 1,
        },
    })->has_no_system_error->has_error->result;
is $used_apps->{error}->{code}, 'InvalidToken', 'not valid after revoke';

$res = $c->call_ok(
    'api_token',
    {
        token => $token,
        args  => {
            api_token    => 1,
            delete_token => $token
        },
    })->has_no_system_error->has_no_error->result;
is scalar(@{$res->{tokens}}), 0, "token deleted successfully";

done_testing();
