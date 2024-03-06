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
use BOM::Config::Redis;
use BOM::OAuth::Passkeys::PasskeysService;

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
my $email    = 'abc@deriv.com';
my $password = 'Abcd12345';

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

# Mock secure cookie session as false as http is used in tests.
my $mocked_cookie_session = Test::MockModule->new('Mojolicious::Sessions');
$mocked_cookie_session->mock(
    'secure' => sub {
        return 0;
    });

my $mock_oauth            = Test::MockModule->new('BOM::Database::Model::OAuth');
my $mock_passkeys_service = Test::MockModule->new('BOM::OAuth::Passkeys::PasskeysService');
my $mock_oauth_controller = Test::MockModule->new('BOM::OAuth::O');
$mock_oauth_controller->mock(
    'csrf_token' => sub {
        return 'csrf_token';
    });

my $t   = Test::Mojo->new('BOM::OAuth');
my $url = "/authorize?app_id=$app_id&brand=deriv";

subtest 'successful passkeys web login for official apps' => sub {
    $mock_passkeys_service->mock(
        'get_user_details' => sub {
            return {binary_user_id => $user->id};
        });
    $mock_oauth->mock('is_official_app' => sub { return 1; });

    $t->post_ok(
        $url => form => {
            publicKeyCredentials => '{"id":"test"}',
            csrf_token           => 'csrf_token',
            passkeys_login       => 1,

        })->status_is(302);
};

subtest 'add passkeys error to template in case of passkeys login error' => sub {
    my %template;
    $mock_oauth_controller->mock(
        'render',
        sub {
            my ($self, %template_params) = @_;
            %template = %template_params;
            return $mock_oauth_controller->original('render')->(@_);
        });
    $mock_passkeys_service->mock(
        'get_user_details' => sub {
            die {
                code    => 'error',
                message => 'message'
            };
        });
    $mock_oauth->mock('is_official_app' => sub { return 1; });
    $t->post_ok(
        $url => form => {
            publicKeyCredentials => '{"id":"test"}',
            csrf_token           => 'csrf_token',
            passkeys_login       => 1,

        })->status_is(200);
    is($template{passkeys_error}, 'error', 'passkeys error added to template');
};

done_testing();
