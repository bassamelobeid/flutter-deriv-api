use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::SessionCookie;
use BOM::System::Password;
use BOM::Platform::User;
use BOM::Platform::Client;
use BOM::Database::Model::OAuth;

my $t = build_mojo_test();

# cleanup
my $oauth = BOM::Database::Model::OAuth->new;
my $dbh   = $oauth->dbh;
$dbh->do("DELETE FROM oauth.access_token");
$dbh->do("DELETE FROM oauth.user_scope_confirm");
$dbh->do("DELETE FROM oauth.apps WHERE id <> 'binarycom'");

my $email     = 'abc@binary.com';
my $password  = 'jskjd8292922';
my $hash_pwd  = BOM::System::Password::hashpw($password);
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client_cr->set_default_account('USD');
$client_cr->email($email);
$client_cr->save;
my $cr_1 = $client_cr->loginid;
my $user = BOM::Platform::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->save;
$user->add_loginid({loginid => $cr_1});
$user->save;

my $token = BOM::Platform::SessionCookie->new(
    loginid => $cr_1,
    email   => $email,
)->token;
$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $cr_1;

## app register/list/get
$t = $t->send_ok({
        json => {
            app_register => 1,
            name         => 'App 1',
            scopes       => ['read', 'admin'],
            redirect_uri => 'https://www.example.com/',
        }})->message_ok;
my $res = decode_json($t->message->[1]);
test_schema('app_register', $res);
my $app1   = $res->{app_register};
my $app_id = $app1->{app_id};

$t = $t->send_ok({
        json => {
            app_get => $app_id,
        }})->message_ok;
$res = decode_json($t->message->[1]);
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
$res = decode_json($t->message->[1]);
ok $res->{error}->{message} =~ /The name is taken/, 'The name is taken';

$t = $t->send_ok({
        json => {
            app_register => 1,
            name         => 'App 1',
            redirect_uri => 'https://www.example.com/',
        }})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{error}->{message} =~ /Input validation failed: scopes/, 'Input validation failed: scopes';

$t = $t->send_ok({
        json => {
            app_register => 1,
            name         => 'App 1',
            scopes       => ['unknown'],
            redirect_uri => 'https://www.example.com/',
        }})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{error}->{message} =~ /Input validation failed: scopes/, 'Input validation failed: scopes';

$t = $t->send_ok({
        json => {
            app_register => 1,
            name         => 'App 2',
            scopes       => ['read', 'admin'],
            redirect_uri => 'https://www.example2.com/',
        }})->message_ok;
$res = decode_json($t->message->[1]);
test_schema('app_register', $res);
my $app2 = $res->{app_register};

$t = $t->send_ok({
        json => {
            app_list => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
test_schema('app_list', $res);
my $get_apps = [grep { $_->{app_id} ne 'binarycom' } @{$res->{app_list}}];
is_deeply($get_apps, [$app1, $app2], 'app_list ok');

$t = $t->send_ok({
        json => {
            app_delete => $app2->{app_id},
        }})->message_ok;
$res = decode_json($t->message->[1]);
test_schema('app_delete', $res);

$t = $t->send_ok({
        json => {
            app_list => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
test_schema('app_list', $res);
$get_apps = [grep { $_->{app_id} ne 'binarycom' } @{$res->{app_list}}];
is_deeply($get_apps, [$app1], 'app_delete ok');

## for used and revoke
my $test_appid = $app1->{app_id};
$oauth = BOM::Database::Model::OAuth->new;
ok $oauth->confirm_scope($test_appid, $cr_1), 'confirm scope';
my ($access_token) = $oauth->store_access_token_only($test_appid, $cr_1);

$t = build_mojo_test();
$t = $t->send_ok({json => {authorize => $access_token}})->message_ok;
$t = $t->send_ok({
        json => {
            oauth_apps => 1,
        }})->message_ok;
$res = decode_json($t->message->[1]);
test_schema('oauth_apps', $res);

my $used_apps = $res->{oauth_apps};
is scalar(@{$used_apps}), 1;
is $used_apps->[0]->{app_id}, $test_appid, 'app_id 1';
is_deeply([sort @{$used_apps->[0]->{scopes}}], ['admin', 'read'], 'scopes are right');
ok $used_apps->[0]->{last_used}, 'last_used ok';

my $is_confirmed = BOM::Database::Model::OAuth->new->is_scope_confirmed($test_appid, $cr_1);
is $is_confirmed, 1, 'was confirmed';
$t = $t->send_ok({
        json => {
            oauth_apps => 1,
            revoke_app => $test_appid,
        }})->message_ok;
$res = decode_json($t->message->[1]);
$is_confirmed = BOM::Database::Model::OAuth->new->is_scope_confirmed($test_appid, $cr_1);
is $is_confirmed, 0, 'not confirmed after revoke';

## the access_token is not working after revoke
$t = $t->send_ok({
        json => {
            oauth_apps => 1,
            revoke_app => $test_appid,
        }})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'InvalidToken', 'not valid after revoke';

$t->finish_ok;

done_testing();
