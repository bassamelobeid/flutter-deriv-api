use strict;
use warnings;
use Test::More;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::User;
use BOM::Platform::Client;
use BOM::System::Password;

use BOM::RPC::v3::App;
use BOM::Database::Model::OAuth;

my $email       = 'abc@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::System::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
$test_client->email($email);
$test_client->save;
my $test_loginid = $test_client->loginid;
my $user         = BOM::Platform::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->save;
$user->add_loginid({loginid => $test_loginid});
$user->save;

# cleanup
BOM::Database::Model::OAuth->new->dbh->do("
    DELETE FROM oauth.clients WHERE binary_user_id = ? AND id <> 'binarycom'
", undef, $user->id);

my $app1 = BOM::RPC::v3::App::register({
        client_loginid => $test_loginid,
        args           => {
            name => 'App 1',
        }});
my $get_app = BOM::RPC::v3::App::get({
        client_loginid => $test_loginid,
        args           => {
            app_get => $app1->{client_id},
        }});
is_deeply($app1, $get_app, 'same on get');

my $res = BOM::RPC::v3::App::register({
        client_loginid => $test_loginid,
        args           => {
            name => 'App 1',
        }});
ok $res->{error}->{message_to_client} =~ /The name is taken/, 'The name is taken';

my $app2 = BOM::RPC::v3::App::register({
        client_loginid => $test_loginid,
        args           => {
            name => 'App 2',
        }});
my $get_apps = BOM::RPC::v3::App::list({
        client_loginid => $test_loginid,
        args           => {
            app_list => 1,
        }});
$get_apps = [grep { $_->{client_id} ne 'binarycom' } @$get_apps];
is_deeply($get_apps, [$app1, $app2], 'list ok');

done_testing();
