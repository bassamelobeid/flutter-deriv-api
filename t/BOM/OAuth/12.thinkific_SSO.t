use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Mojo;
use JSON::WebToken;
use Mojo::URL;
use BOM::User::Client;
use BOM::Database::Model::OAuth;
use BOM::OAuth::Thinkific;

my $oauth = BOM::Database::Model::OAuth->new;
$oauth->dbic->dbh->do("DELETE FROM oauth.user_scope_confirm");
$oauth->dbic->dbh->do("DELETE FROM oauth.access_token");
$oauth->dbic->dbh->do("DELETE FROM oauth.official_apps");
$oauth->dbic->dbh->do("DELETE FROM oauth.apps WHERE name='Test App'");

my $app = {
    name         => 'Test App',
    user_id      => 1,
    scopes       => ['read', 'trade', 'admin'],
    redirect_uri => 'https://www.example.com/',
    api_key      => 'mock_api_key'
};
my $app_id   = $oauth->create_app($app)->{app_id};
my $mock_sso = Test::MockModule->new('BOM::OAuth::Thinkific');

my $mock_url = 'https://example.com/mock';

my $mock_payload = {
    first_name  => 'Test',
    last_name   => 'User',
    email       => 'testuser@example.com',
    external_id => '1234567890',
    iat         => time,
};

$mock_sso->mock(
    _thinkific_uri_constructor => sub {
        my ($client, $app) = @_;
        my $base_url = $mock_url;
        my $mock_jwt = encode_jwt $mock_payload, $app->{api_key};
        return Mojo::URL->new($base_url)->query(jwt => $mock_jwt);
    });

# Mock _thinkific_sso_params to return specific parameters
$mock_sso->mock(
    _thinkific_sso_params => sub {
        my ($client) = @_;
        return {
            first_name  => 'John',
            last_name   => 'Doe',
            email       => 'john@example.com',
            external_id => '12345',
            iat         => time,
        };
    });

my $t = Test::Mojo->new('BOM::OAuth');

$t = $t->get_ok("/session/thinkific/create?token1=test_token");
$t->json_is(
    '/error'             => 'invalid_request',
    '/error_description' => 'The request was missing a valid app_id'
);

$t = $t->get_ok("/session/thinkific/create?token1=test_token&app_id=$app_id");
$t->json_is(
    '/error'             => 'invalid_request',
    '/error_description' => 'The request was missing a valid loginId'
);

# Create a mock client and configurations
my $client       = BOM::User::Client->new({'loginid' => 'CR0006'});
my $mock_configs = {
    thinkific_redirect_uri => 'https://example.thinkific.com/sso',
    thinkific_api_key      => 'thinkific_secret_key'                 # Use a consistent mock API key
};

subtest '_thinkific_uri_constructor' => sub {
    my $uri = BOM::OAuth::Thinkific::_thinkific_uri_constructor($client, $app);

    # Construct the expected URL using the consistent mock payload and API key
    my $expected_jwt = encode_jwt $mock_payload, 'mock_api_key';
    my $expected_url = Mojo::URL->new($mock_url)->query(jwt => $expected_jwt);    # Use the mock URL

    is($uri, $expected_url, 'Returns the correct URI');
};

my $thinkific_params = BOM::OAuth::Thinkific::_thinkific_sso_params($client);

is($thinkific_params->{first_name},  'John',             'Thinkific SSO params include first name');
is($thinkific_params->{last_name},   'Doe',              'Thinkific SSO params include last name');
is($thinkific_params->{email},       'john@example.com', 'Thinkific SSO params include email');
is($thinkific_params->{external_id}, '12345',            'Thinkific SSO params include external_id');
ok($thinkific_params->{iat} <= time, 'Thinkific SSO params include iat <= current time');

done_testing;

