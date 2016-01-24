use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::System::Password;
use BOM::Platform::User;
use BOM::Platform::Client;
use BOM::Database::Model::OAuth;

my $t = build_mojo_test();

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

# cleanup
BOM::Database::Model::OAuth->new->dbh->do("
    DELETE FROM oauth.apps WHERE binary_user_id = ? AND id <> 'binarycom'
", undef, $user->id);

## app register/list/get
$t = $t->send_ok({
        json => {
            app_register => 1,
            name         => 'App 1'
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

$t = $t->send_ok({
        json => {
            app_register => 1,
            name         => 'App 2'
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
my $get_apps = [grep { $_->{app_id} ne 'binarycom' } @{$res->{app_list}}];
is_deeply($get_apps, [$app1], 'app_delete ok');

$t->finish_ok;

done_testing();
