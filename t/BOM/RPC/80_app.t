use strict;
use warnings;
use Test::More;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use TestHelper qw/create_test_user/;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::User;
use BOM::Platform::Client;
use BOM::System::Password;
use BOM::RPC::v3::App;
use BOM::RPC::v3::Accounts;
use BOM::Database::Model::OAuth;
use BOM::Database::Model::AccessToken;

# cleanup
my $dbh = BOM::Database::Model::OAuth->new->dbh;
$dbh->do("DELETE FROM oauth.apps WHERE id <> 'binarycom'");

my $test_loginid = create_test_user();

# cleanup
BOM::Database::Model::AccessToken->new->remove_by_loginid($test_loginid);

my $mock_utility = Test::MockModule->new('BOM::RPC::v3::Utility');
# need to mock it as to access api token we need token beforehand
$mock_utility->mock('token_to_loginid', sub { return $test_loginid });

# create new api token
my $res = BOM::RPC::v3::Accounts::api_token({
        token => 'Abc123',
        args  => {
            api_token => 1,
            new_token => 'Sample1'
        }});
is scalar(@{$res->{tokens}}), 1, "token created succesfully";
my $token = $res->{tokens}->[0]->{token};

$mock_utility->unmock('token_to_loginid');

my $app1 = BOM::RPC::v3::App::register({
        token => $token,
        args  => {
            name         => 'App 1',
            scopes       => ['read', 'trade'],
            redirect_uri => 'https://www.example.com/',
        }});
my $get_app = BOM::RPC::v3::App::get({
        token => $token,
        args  => {
            app_get => $app1->{app_id},
        }});
is_deeply($app1, $get_app, 'same on get');

$res = BOM::RPC::v3::App::register({
        token => $token,
        args  => {
            name => 'App 1',
        }});
ok $res->{error}->{message_to_client} =~ /The name is taken/, 'The name is taken';

my $app2 = BOM::RPC::v3::App::register({
        token => $token,
        args  => {
            name         => 'App 2',
            scopes       => ['read', 'admin'],
            redirect_uri => 'https://www.example2.com/',
        }});
my $get_apps = BOM::RPC::v3::App::list({
        token => $token,
        args  => {
            app_list => 1,
        }});
$get_apps = [grep { $_->{app_id} ne 'binarycom' } @$get_apps];
is_deeply($get_apps, [$app1, $app2], 'list ok');

my $delete_st = BOM::RPC::v3::App::delete({
        token => $token,
        args  => {
            app_delete => $app2->{app_id},
        }});
ok $delete_st;
$get_apps = BOM::RPC::v3::App::list({
        token => $token,
        args  => {
            app_list => 1,
        }});
$get_apps = [grep { $_->{app_id} ne 'binarycom' } @$get_apps];
is_deeply($get_apps, [$app1], 'delete ok');

# delete again will return 0
$delete_st = BOM::RPC::v3::App::delete({
        token => $token,
        args  => {
            app_delete => $app2->{app_id},
        }});
ok !$delete_st, 'was deleted';

$res = BOM::RPC::v3::Accounts::api_token({
        token => $token,
        args  => {
            api_token    => 1,
            delete_token => $token
        }});
is scalar(@{$res->{tokens}}), 0, "token deleted successfully";

done_testing();
