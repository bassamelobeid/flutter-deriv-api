use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use BOM::User::Password;
use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::User::TOTP;

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

#mock config for growthbook service
$mock_config->mock(
    growthbook_config => sub {
        return {
            is_growthbook_enabled => 'dummy',
            growthbook_client_key => 'dummy'
        };
    });

## create test user to login
my $email      = 'abc@binary.com';
my $password   = 'jskjd8292922';
my $secret_key = BOM::User::TOTP->generate_key();
my $hash_pwd   = BOM::User::Password::hashpw($password);
my $client_cr  = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email
});
$client_cr->save;
my $cr_loginid = $client_cr->loginid;
my $user       = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->add_client($client_cr);
$user->update_totp_fields(
    secret_key      => $secret_key,
    is_totp_enabled => 1
);

my $t = Test::Mojo->new('BOM::OAuth');

# mock domain_name to suppress warnings
my $mocked_request = Test::MockModule->new('BOM::Platform::Context::Request');
$mocked_request->mock('domain_name', 'www.binaryqa.com');

$t = $t->get_ok("/authorize?app_id=$app_id")->content_like(qr/login/);

my $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
ok $csrf_token, 'csrf_token is there';

my $mock_session = Test::MockModule->new('BOM::Database::Model::OAuth');

my $mock_history = Test::MockModule->new('BOM::User');
$mock_history->mock(
    'get_last_successful_login_history' => sub {
        return {"environment" => "IP=1.1.1.1 IP_COUNTRY=1.1.1.1 User_AGENT=ABC LANG=AU"};
    });

my $mocked_oauth = Test::MockModule->new('BOM::OAuth::O');
$mocked_oauth->mock(
    'send_email',
    sub {
        my $arg = shift;
        is $arg->{subject}, 'Security alert: New sign-in activity', 'Unrecognised Sign-in email subject';
    });

my $callPost = sub {
    my ($t, $email, $password, $csrf_token, $lang) = @_;

    $t->post_ok(
        "/authorize?app_id=$app_id" => form => {
            login      => 1,
            email      => $email,
            password   => $password,
            csrf_token => $csrf_token,
        });
    return $t;
};

$callPost->($t, $email, $password, $csrf_token);

done_testing();
