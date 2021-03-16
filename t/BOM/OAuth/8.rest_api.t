use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::MockModule;
use Test::Deep;
use Date::Utility;
use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use Digest::SHA qw(hmac_sha256_hex);
use JSON::WebToken;

my $t = Test::Mojo->new('BOM::OAuth');
my $app;
my $app_id = do {
    my $oauth = BOM::Database::Model::OAuth->new;
    $oauth->dbic->dbh->do("DELETE FROM oauth.user_scope_confirm");
    $oauth->dbic->dbh->do("DELETE FROM oauth.access_token");
    $oauth->dbic->dbh->do("DELETE FROM oauth.apps WHERE name='Test App'");
    $app = $oauth->create_app({
        name         => 'Test App',
        user_id      => 1,
        scopes       => ['read', 'trade', 'admin'],
        redirect_uri => 'https://www.example.com/'
    });
    $app->{app_id};
};

# Ensure we use a dummy secret for hmac signing
my $api_mock = Test::MockModule->new('BOM::OAuth::RestAPI');
$api_mock->mock('_secret', sub { 'dummy' });

# Create a challenge from app_id and expire using the dummy secret
my $challenger = sub {
    my ($app_id, $expire) = @_;

    my $payload = join ',', $app_id, $expire;
    return hmac_sha256_hex($payload, 'dummy');
};

# Helper to hit the api with a POST request
my $post = sub {
    my ($url, $payload) = @_;
    return $t->post_ok($url => json => $payload);
};

my $challenge;
my $expire;

subtest 'verify' => sub {
    my $url = '/api/v1/verify';

    my $response = $post->($url, {app_id => $app_id})->status_is(200)->json_has('/challenge', 'Response has a challenge')
        ->json_has('/expire', 'Response has an expire')->tx->res->json;

    $challenge = $response->{challenge};
    $expire    = $response->{expire};

    ok $challenge, 'Got the challenge from the JSON response';
    ok $expire,    'Got the expire from the JSON response';

    my $expected_challenge = $challenger->($app_id, $expire);
    is $expected_challenge, $challenge, 'The challenge looks good';
};

my $jwt_token;

subtest 'authorize' => sub {
    my $url      = '/api/v1/authorize';
    my $solution = hmac_sha256_hex($challenge, 'tok3n');

    # should've been ok but no token in our app_token table
    $post->(
        $url,
        {
            app_id   => $app_id,
            expire   => $expire,
            solution => $solution
        })->status_is(401);

    # create the token
    my $m = BOM::Database::Model::OAuth->new;
    ok $m->create_app_token($app_id, 'tok3n'), 'App token has been created';

    # bad solution
    $post->(
        $url,
        {
            app_id   => $app_id,
            expire   => $expire,
            solution => 'bad'
        })->status_is(401);

    # expired
    $post->(
        $url,
        {
            app_id   => $app_id,
            expire   => 0,
            solution => $challenger->($app_id, 0)})->status_is(401);

    # no expired
    $post->(
        $url,
        {
            app_id   => $app_id,
            solution => $challenger->($app_id, 0)})->status_is(401);

    # the app is deactivated
    $app->{active} = 0;
    $m->update_app($app_id, $app);
    $post->(
        $url,
        {
            app_id   => $app_id,
            expire   => $expire,
            solution => $solution
        })->status_is(401);

    # success
    $app->{active} = 1;
    $m->update_app($app_id, $app);

    my $response = $post->(
        $url,
        {
            app_id   => $app_id,
            expire   => $expire,
            solution => $solution
        })->status_is(200)->json_has('/token', 'Response has a token')->tx->res->json;

    $jwt_token = $response->{token};
    ok $jwt_token, 'Got the JWT token from the JSON response';

    my $decoded = decode_jwt $jwt_token, 'dummy';
    cmp_deeply $decoded,
        {
        app => $app_id,
        sub => 'auth',
        exp => re('\d+')
        },
        'JWT looks good';
};

$api_mock->unmock_all;

done_testing()
