use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::MockModule;

use BOM::User::Password;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Database::Model::OAuth;
use BOM::Config::Runtime;
use BOM::OAuth::O;

use utf8;

## init
my $app_id = do {
    my $oauth = BOM::Database::Model::OAuth->new;
    $oauth->dbic->dbh->do("DELETE FROM oauth.user_scope_confirm");
    $oauth->dbic->dbh->do("DELETE FROM oauth.access_token");
    $oauth->dbic->dbh->do("DELETE FROM oauth.apps WHERE name='Test App'");
    my $app = $oauth->create_app({
        name         => 'Test App',
        user_id      => 1,
        scopes       => ['read', 'trade'],
        redirect_uri => 'https://www.example.com/'
    });
    $app->{app_id};
};

#mock config for social login service
my $mock_config = Test::MockModule->new('BOM::Config');
$mock_config->mock(
    service_social_login => sub {
        return {
            social_login => {
                port => 'dummy',
                host => 'dummy'
            }};
    });

## create test user to login
my $email    = 'abc@binary.com';
my $password = 'jskjd8292922';
my $client_cr;
{
    my $hash_pwd = BOM::User::Password::hashpw($password);
    $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_cr->email($email);
    $client_cr->save;
}

# mock domain_name to suppress warnings
my $mocked_request = Test::MockModule->new('BOM::Platform::Context::Request');
$mocked_request->mock('domain_name', 'www.binaryqa.com');

# Mock secure cookie session as false as http is used in tests.
my $mocked_cookie_session = Test::MockModule->new('Mojolicious::Sessions');
$mocked_cookie_session->mock(
    'secure' => sub {
        return 0;
    });

my $t = Test::Mojo->new('BOM::OAuth');

$t = $t->get_ok("/authorize?app_id=$app_id")->content_like(qr/login/);
my $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
ok $csrf_token, 'csrf_token is there';

my $mock_history = Test::MockModule->new('BOM::User');
$mock_history->mock(
    'get_last_successful_login_history' => sub {
        return {"environment" => "IP=1.1.1.1 IP_COUNTRY=1.1.1.1 User_AGENT=ABC LANG=AU"};
    });

my $mock_common = Test::MockModule->new('BOM::OAuth::Common');
$mock_common->mock(
    'validate_login' => sub {
        return {
            clients      => [$client_cr],
            login_result => {self_closed => 0}};
    });

$t->post_ok(
    "/authorize?app_id=$app_id" => form => {
        login      => 1,
        email      => $email,
        password   => $password,
        csrf_token => $csrf_token
    });

$t = $t->content_like(qr/Invalid user/);

is BOM::OAuth::O::_website_domain($t, undef), 'deriv.com', 'no die when app id is undef';
is BOM::OAuth::O::_website_domain($t, 15284), 'binary.me', 'correct website when passed a valid app id';

done_testing();
