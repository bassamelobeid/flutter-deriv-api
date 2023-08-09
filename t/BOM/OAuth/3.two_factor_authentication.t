use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::MockModule;
use Authen::OATH;
use BOM::User::Password;
use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::User::TOTP;

## init
my $app_id = do {
    my $oauth = BOM::Database::Model::OAuth->new;
    $oauth->dbic->dbh->do("DELETE FROM oauth.user_scope_confirm");
    $oauth->dbic->dbh->do("DELETE FROM oauth.access_token");
    $oauth->dbic->dbh->do("DELETE FROM oauth.apps WHERE name='Test App'");
    my $app = $oauth->create_app({
        name         => 'Test App',
        user_id      => 1,
        scopes       => ['read', 'trade', 'admin'],
        redirect_uri => 'https://www.example.com/'
    });
    $app->{app_id};
};

## create test user to login
my $email      = 'abc@binary.com';
my $password   = 'jskjd8292922';
my $secret_key = BOM::User::TOTP->generate_key();
{
    my $hash_pwd  = BOM::User::Password::hashpw($password);
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_cr->email($email);
    $client_cr->save;
    my $user = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->add_client($client_cr);
    $user->update_totp_fields(
        secret_key      => $secret_key,
        is_totp_enabled => 1
    );
}

# mock domain_name to suppress warnings
my $mocked_request = Test::MockModule->new('BOM::Platform::Context::Request');
$mocked_request->mock('domain_name', 'www.binaryqa.com');

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

# Mock secure cookie session as false as http is used in tests.
my $mocked_cookie_session = Test::MockModule->new('Mojolicious::Sessions');
$mocked_cookie_session->mock(
    'secure' => sub {
        return 0;
    });

my $mock_history = Test::MockModule->new('BOM::User');
$mock_history->mock(
    'get_last_successful_login_history' => sub {
        return {"environment" => "IP=1.1.1.1 IP_COUNTRY=1.1.1.1 User_AGENT=ABC LANG=AU"};
    });

my $t = Test::Mojo->new('BOM::OAuth');
$t = $t->get_ok("/authorize?app_id=$app_id")->content_like(qr/login/);

my $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
ok $csrf_token, 'csrf_token is there';
$t->post_ok(
    "/authorize?app_id=$app_id" => form => {
        login      => 1,
        email      => $email,
        password   => $password,
        csrf_token => $csrf_token
    });

# Check for OTP Page after login
$t = $t->content_like(qr/totp_proceed/);

$csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
ok $csrf_token, 'csrf_token is there';

$t->post_ok(
    "/authorize?app_id=$app_id" => form => {
        totp_proceed => 1,
        otp          => Authen::OATH->new()->totp($secret_key),
        csrf_token   => $csrf_token
    });

# confirm_scopes after login
$t = $t->content_like(qr/confirm_scopes/);

$csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
ok $csrf_token, 'csrf_token is there';

$t->post_ok(
    "/authorize?app_id=$app_id" => form => {
        confirm_scopes => 'read,trade,admin',
        csrf_token     => $csrf_token
    });

ok $t->tx->res->headers->location =~ 'https://www.example.com/', 'redirect to example';
my ($code) = ($t->tx->res->headers->location =~ /token1=(.*?)$/);
ok $code, 'got access code';

done_testing();
