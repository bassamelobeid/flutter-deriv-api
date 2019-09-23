use strict;
use warnings;
use Test::More;
use Encode;
use JSON::MaybeXS;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::User::Password;
use BOM::User;
use BOM::User::Client;
use BOM::Database::Model::OAuth;
use Test::Deep;
use Test::Warnings qw(warnings);

my $t    = build_wsapi_test();
my $json = JSON::MaybeXS->new;

# cleanup
my $oauth = BOM::Database::Model::OAuth->new;
my $dbh   = $oauth->dbic->dbh;
$dbh->do("DELETE FROM oauth.access_token");
$dbh->do("DELETE FROM oauth.user_scope_confirm");
$dbh->do("DELETE FROM oauth.official_apps");
$dbh->do("DELETE FROM oauth.apps WHERE id <> 1");

my $email     = 'abc@binary.com';
my $password  = 'jskjd8292922';
my $hash_pwd  = BOM::User::Password::hashpw($password);
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client_cr->set_default_account('USD');
$client_cr->email($email);
$client_cr->save;
my $cr_1 = $client_cr->loginid;
my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->add_client($client_cr);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $cr_1);

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = $json->decode(Encode::decode_utf8($t->message->[1]));
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $cr_1;

## app register/list/get
$t = $t->send_ok({
        json => {
            app_register => 1,
            name         => 'App with no admin',
            scopes       => ['read', 'trade'],
            redirect_uri => 'https://www.example.com/',
            homepage     => 'https://www.homepage.com/',
        }})->message_ok;
my $res          = $json->decode(Encode::decode_utf8($t->message->[1]));
my $app_no_admin = $res->{app_register};

$t = $t->send_ok({
        json => {
            app_register => 1,
            name         => 'App 1',
            scopes       => ['read', 'trade'],
            redirect_uri => 'https://www.example.com/',
            homepage     => 'https://www.homepage.com/',
        }})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{msg_type}, 'app_register';
test_schema('app_register', $res);
my $app1   = $res->{app_register};
my $app_id = $app1->{app_id};
is_deeply([sort @{$app1->{scopes}}], ['read', 'trade'], 'scopes are right');
is $app1->{redirect_uri}, 'https://www.example.com/',  'redirect_uri is right';
is $app1->{homepage},     'https://www.homepage.com/', 'homepage is right';

$t = $t->send_ok({
        json => {
            app_update   => $app_id,
            name         => 'App 1',
            scopes       => ['read', 'admin', 'trade'],
            redirect_uri => 'https://www.example.com/callback',
            homepage     => 'https://www.homepage2.com/',
        }})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{msg_type}, 'app_update';
test_schema('app_update', $res);
$app1 = $res->{app_update};
is_deeply([sort @{$app1->{scopes}}], ['admin', 'read', 'trade'], 'scopes are updated');
is $app1->{redirect_uri}, 'https://www.example.com/callback', 'redirect_uri is updated';
is $app1->{homepage},     'https://www.homepage2.com/',       'homepage is updated';

$t = $t->send_ok({
        json => {
            app_get => $app_id,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{msg_type}, 'app_get';
test_schema('app_get', $res);
is_deeply($res->{app_get}, $app1, 'app_get ok');

## validation
$t = $t->send_ok({
        json => {
            app_register => 1,
            name         => 'App 1',
            scopes       => ['read', 'admin'],
            redirect_uri => 'https://www.example.com/',
        }})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{msg_type}, 'app_register';
ok $res->{error}->{message} =~ /The name is taken/, 'The name is taken';

$t = $t->send_ok({
        json => {
            app_register => 1,
            name         => 'App 1',
            redirect_uri => 'https://www.example.com/',
        }})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
ok $res->{error}->{message} =~ /Input validation failed: scopes/, 'Input validation failed: scopes';

$t = $t->send_ok({
        json => {
            app_register => 1,
            name         => 'App 1',
            scopes       => ['unknown'],
            redirect_uri => 'https://www.example.com/',
        }})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
ok $res->{error}->{message} =~ /Input validation failed: scopes/, 'Input validation failed: scopes';

$t = $t->send_ok({
        json => {
            app_register => 1,
            name         => 'App 2',
            scopes       => ['read', 'admin'],
            redirect_uri => 'https://www.example2.com/',
        }})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
test_schema('app_register', $res);
my $app2 = $res->{app_register};

$t = $t->send_ok({
        json => {
            app_list => 1,
        }})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{msg_type}, 'app_list';
test_schema('app_list', $res);
my $get_apps = [grep { $_->{app_id} ne '1' } @{$res->{app_list}}];

is_deeply($get_apps, [$app1, $app2, $app_no_admin], 'app_list ok');

$t = $t->send_ok({
        json => {
            app_delete => $app2->{app_id},
        }})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{msg_type}, 'app_delete';
test_schema('app_delete', $res);

$t = $t->send_ok({
        json => {
            app_list => 1,
        }})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
test_schema('app_list', $res);
$get_apps = [grep { $_->{app_id} ne '1' } @{$res->{app_list}}];
is_deeply($get_apps, [$app1, $app_no_admin], 'app_delete ok');

## for used and revoke
my $test_appid = $app1->{app_id};
$oauth = BOM::Database::Model::OAuth->new;
ok $oauth->confirm_scope($test_appid, $cr_1), 'confirm scope';
my ($access_token) = $oauth->store_access_token_only($test_appid, $cr_1);

$t->finish_ok;

$t = build_wsapi_test();
$t = $t->send_ok({json => {authorize => $access_token}})->message_ok;
$t = $t->send_ok({
        json => {
            oauth_apps => 1,
        }})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{msg_type}, 'oauth_apps';
test_schema('oauth_apps', $res);

my $used_apps = $res->{oauth_apps};
is scalar(@{$used_apps}), 1;
is $used_apps->[0]->{app_id}, $test_appid, 'app_id 1';
is_deeply([sort @{$used_apps->[0]->{scopes}}], ['admin', 'read', 'trade'], 'scopes are right');
ok $used_apps->[0]->{last_used}, 'last_used ok';

my $is_confirmed = BOM::Database::Model::OAuth->new->is_scope_confirmed($test_appid, $cr_1);
is $is_confirmed, 1, 'was confirmed';
$t = $t->send_ok({
        json => {
            revoke_oauth_app => $test_appid,
        }})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
$is_confirmed = BOM::Database::Model::OAuth->new->is_scope_confirmed($test_appid, $cr_1);
is $is_confirmed, 0, 'not confirmed after revoke';

## the access_token is not working after revoke
$t = $t->send_ok({
        json => {
            oauth_apps => 1,
        }})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{msg_type}, 'oauth_apps';
is $res->{error}->{code}, 'InvalidToken', 'not valid after revoke';

$t->finish_ok;

$t = build_wsapi_test({app_id => $app1->{app_id}});
$t = $t->send_ok({json => {authorize => $token}})->message_ok;
$t = $t->send_ok({
        json => {
            app_get => $app1->{app_id},
        }})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{msg_type}, 'app_get';
test_schema('app_get', $res);
is_deeply($res->{app_get}, $app1, 'app_get ok');

$t->finish_ok;

## cannot revoke without admin scope
$t = build_wsapi_test();
$t->send_ok({json => {ping => 1}})->message_ok;
my $app_no_admin_id = $app_no_admin->{app_id};
$oauth = BOM::Database::Model::OAuth->new;
ok $oauth->confirm_scope($app_no_admin_id, $cr_1), 'confirm scope';
($access_token) = $oauth->store_access_token_only($app_no_admin_id, $cr_1);

$t->finish_ok;

$t = build_wsapi_test();
$t = $t->send_ok({json => {authorize => $access_token}})->message_ok;
$t = $t->send_ok({
        json => {
            oauth_apps => 1,
        }})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{msg_type}, 'oauth_apps';
test_schema('oauth_apps', $res);
$used_apps = $res->{oauth_apps};
is scalar(@{$used_apps}), 1;
is $used_apps->[0]->{app_id}, $app_no_admin_id, 'app_id app_no_admin_id';
is_deeply([sort @{$used_apps->[0]->{scopes}}], ['read', 'trade'], 'scopes are right');

$is_confirmed = BOM::Database::Model::OAuth->new->is_scope_confirmed($app_no_admin_id, $cr_1);
is $is_confirmed, 1, 'was confirmed';
$t = $t->send_ok({
        json => {
            revoke_oauth_app => $test_appid,
        }})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{error}{code}, 'PermissionDenied', 'revoke_oauth_app failed';

$t->finish_ok;

$t = build_wsapi_test({app_id => 333});
$t = $t->send_ok({json => {authorize => $token}})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{msg_type}, 'authorize';
is $res->{error}->{code}, 'InvalidAppID', 'Should return error if get wrong app_id and close connection';
$t->finished_ok(1005);

$t = build_wsapi_test({app_id => $app1->{app_id}});
$t = $t->send_ok({json => {time => 1}})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
ok(!$res->{error}, 'no error at first');
$Binary::WebSocketAPI::BLOCK_APP_IDS{$app1->{app_id}} = 1;
$t = $t->send_ok({json => {time => 1}})->message_ok;
$t->finished_ok(403);
# avoid warn 'used only once warning'
delete $Binary::WebSocketAPI::BLOCK_APP_IDS{$app1->{app_id}};
done_testing();
