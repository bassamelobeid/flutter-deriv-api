use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::MockModule;
use Test::Deep;
use Test::Warn;
use Date::Utility;
use BOM::Database::Model::OAuth;
use BOM::User::Password;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Digest::SHA qw(hmac_sha256_hex);
use JSON::WebToken;

my $redis = BOM::Config::Redis::redis_auth_write();
my $t     = Test::Mojo->new('BOM::OAuth');
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

# Create users
my $password = 'jskjd8292922';
my $hash_pwd = BOM::User::Password::hashpw($password);

# Create test system created user
my $system_user_email = 'system@binary.com';

my $system_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$system_client_cr->email($system_user_email);
$system_client_cr->save;
my $sytem_user = BOM::User->create(
    email    => $system_user_email,
    password => $hash_pwd
);
$sytem_user->add_client($system_client_cr);

# Create test social created user
my $social_user_email = 'social@binary.com';

my $social_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$social_client_cr->email($social_user_email);
$social_client_cr->save;
my $social_user = BOM::User->create(
    email             => $social_user_email,
    password          => $hash_pwd,
    has_social_signup => 1
);
$social_user->add_client($social_client_cr);

# Ensure we use a dummy secret for hmac signing
my $api_mock = Test::MockModule->new('BOM::OAuth::RestAPI');
$api_mock->mock('_secret', sub { 'dummy' });

# Rest API is only for official apps
my $is_official_app;
my $model_mock = Test::MockModule->new('BOM::Database::Model::OAuth');
$model_mock->mock('is_official_app', sub { $is_official_app });

# Mocking BOM::User::TOTP since _verify_otp only checks if is_totp_enabled then calls verify_totp
my $totp_mock  = Test::MockModule->new('BOM::User::TOTP');
my $totp_value = '323667';
$totp_mock->mock(
    'verify_totp',
    sub {
        my (undef, undef, $totp) = @_;
        return $totp eq $totp_value;
    });

# Create a challenge from app_id and expire using the dummy secret
my $challenger = sub {
    my ($app_id, $expire) = @_;

    my $payload = join ',', $app_id, $expire;
    return hmac_sha256_hex($payload, 'dummy');
};

# Helper to hit the api with a POST request
my $post = sub {
    my ($url, $payload, $headers) = @_;

    return $t->post_ok($url => $headers => json => $payload) if $headers;
    return $t->post_ok($url => json     => $payload);
};

my $challenge;
my $expire;

subtest 'verify' => sub {
    my $url = '/api/v1/verify';

    note "Non json request body";
    warning_like {
        $t->post_ok($url => "string body")->status_is(400)->json_is('/error_code', 'NEED_JSON_BODY');
    }
    qr/domain/;

    $is_official_app = 0;
    # unofficial app is restricted
    $post->($url, {app_id => $app_id})->status_is(400)->json_is('/error_code', 'UNOFFICIAL_APP');
    $is_official_app = 1;

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

    note "Non json request body";
    warning_like {
        $t->post_ok($url => "string body")->status_is(400)->json_is('/error_code', 'NEED_JSON_BODY');
    }
    qr/domain/;

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
            expire   => 1,
            solution => $challenger->($app_id, 1)})->status_is(400)->json_is('/error_code', 'INVALID_EXPIRE_TIMESTAMP');

    # no expired
    $post->(
        $url,
        {
            app_id   => $app_id,
            solution => $challenger->($app_id, 0)})->status_is(400)->json_is('/error_code', 'INVALID_EXPIRE_TIMESTAMP');

    # the app is deactivated
    $app->{active} = 0;
    $m->update_app($app_id, $app);
    $post->(
        $url,
        {
            app_id   => $app_id,
            expire   => $expire,
            solution => $solution
        })->status_is(400)->json_is('/error_code', 'INVALID_APP_ID');

    # activate the app
    $app->{active} = 1;
    $m->update_app($app_id, $app);

    # unofficial app
    $is_official_app = 0;
    $post->(
        $url,
        {
            app_id   => $app_id,
            expire   => $expire,
            solution => $solution
        })->status_is(400)->json_is('/error_code', 'UNOFFICIAL_APP');

    # success
    $is_official_app = 1;

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

subtest 'login' => sub {
    my $authorize_url = '/api/v1/authorize';
    my $solution      = hmac_sha256_hex($challenge, 'tok3n');

    my $oauth = BOM::Database::Model::OAuth->new;
    ok $oauth->create_app_token($app_id, 'tok3n'), 'App token has been created';

    $app->{active} = 1;
    $oauth->update_app($app_id, $app);

    my $response = $post->(
        $authorize_url,
        {
            app_id   => $app_id,
            expire   => $expire,
            solution => $solution
        })->status_is(200)->json_has('/token', 'Response has a token')->tx->res->json;

    my $jwt_token = $response->{token};
    ok $jwt_token, 'Got the JWT token from the JSON response';

    my $login_url = '/api/v1/login';

    note "Non json request body";
    warning_like {
        $t->post_ok($login_url => "string body")->status_is(400)->json_is('/error_code', 'NEED_JSON_BODY');
    }
    qr/domain/;

    note "Wrong token";
    $post->(
        $login_url,
        {app_id => $app_id},
        {
            Authorization => "Bearer Wrong token",
        })->status_is(401)->json_is('/error_code', 'INVALID_TOKEN');

    note "Wrong app id";
    $post->(
        $login_url,
        {app_id => '11111'},
        {
            Authorization => "Bearer $jwt_token",
        })->status_is(400)->json_is('/error_code', 'INVALID_APP_ID');

    note "Unofficial app";
    $is_official_app = 0;
    $post->(
        $login_url,
        {app_id => $app_id},
        {
            Authorization => "Bearer $jwt_token",
        })->status_is(400)->json_is('/error_code', 'UNOFFICIAL_APP');
    $is_official_app = 1;

    note "Wrong login type";
    my $client_ip = $post->(
        $login_url,
        {
            app_id => $app_id,
            type   => 'wrong'
        },
        {
            Authorization => "Bearer $jwt_token",
        })->status_is(400)->json_is('/error_code', 'INVALID_LOGIN_TYPE')->tx->original_remote_address;

    note "Wrong date first contact";
    $post->(
        $login_url,
        {
            app_id             => $app_id,
            type               => 'social',
            date_first_contact => "20-02-2020"    # correct format is yyyy-mm-dd
        },
        {
            Authorization => "Bearer $jwt_token",
        }
    )->status_is(400)->json_is(
        '/error_code',
        'INVALID_DATE_FIRST_CONTACT'
    );

    note "Blocked client ip";
    my $block_redis_key = "oauth::blocked_by_ip::$client_ip";
    $redis->set($block_redis_key, 1);
    $post->(
        $login_url,
        {
            app_id => $app_id,
            type   => 'system'
        },
        {
            Authorization => "Bearer $jwt_token",
        })->status_is(429)->json_is('/error_code', 'SUSPICIOUS_BLOCKED');
    $redis->del($block_redis_key);

    subtest 'Login via system' => sub {
        my $login_type = 'system';
        note "Wrong email";
        $post->(
            $login_url,
            {
                app_id => $app_id,
                type   => $login_type,
                email  => ''
            },
            {
                Authorization => "Bearer $jwt_token",
            })->status_is(400)->json_is('/error_code', 'INVALID_EMAIL');

        note "Wrong password";
        $post->(
            $login_url,
            {
                app_id   => $app_id,
                type     => $login_type,
                email    => $system_user_email,
                password => ''
            },
            {
                Authorization => "Bearer $jwt_token",
            })->status_is(400)->json_is('/error_code', 'INVALID_PASSWORD');

        note "Successful Login";
        $post->(
            $login_url,
            {
                app_id   => $app_id,
                type     => $login_type,
                email    => $system_user_email,
                password => $password
            },
            {
                Authorization => "Bearer $jwt_token",
            })->status_is(200)->json_has('/tokens');

        # Updating system_user to is_totp_enabled
        $sytem_user->update_totp_fields(is_totp_enabled => 1);
        note "Missing ONE TIME PASSWORD";
        $post->(
            $login_url,
            {
                app_id            => $app_id,
                type              => $login_type,
                email             => $system_user_email,
                password          => $password,
                one_time_password => ''
            },
            {
                Authorization => "Bearer $jwt_token",
            })->status_is(400)->json_is('/error_code', 'MISSING_ONE_TIME_PASSWORD');

        note "Wrong ONE TIME PASSWORD";
        $post->(
            $login_url,
            {
                app_id            => $app_id,
                type              => $login_type,
                email             => $system_user_email,
                password          => $password,
                one_time_password => 'XyZxYz'
            },
            {
                Authorization => "Bearer $jwt_token",
            })->status_is(400)->json_is('/error_code', 'TFA_FAILURE');

        note "Successful Login with ONE TIME PASSWORD";
        $post->(
            $login_url,
            {
                app_id            => $app_id,
                type              => $login_type,
                email             => $system_user_email,
                password          => $password,
                one_time_password => $totp_value
            },
            {
                Authorization => "Bearer $jwt_token",
            })->status_is(200)->json_has('/tokens');
    };

    subtest 'Login via social' => sub {
        my $login_type = 'social';

        note "Missed connection token";
        $post->(
            $login_url,
            {
                app_id => $app_id,
                type   => $login_type
            },
            {
                Authorization => "Bearer $jwt_token",
            })->status_is(400)->json_is('/error_code', 'MISSED_CONNECTION_TOKEN');

        note 'Successful Login';
        # Mocking OneAll Data
        my $mocked_oneall = Test::MockModule->new('WWW::OneAll');
        $mocked_oneall->mock(
            new        => sub { bless +{}, 'WWW::OneAll' },
            connection => sub {
                return +{
                    response => {
                        request => {
                            status => {
                                code => 200,
                            },
                        },
                        result => {
                            status => {
                                code => 200,
                                flag => '',
                            },
                            data => {
                                user => {
                                    identity => {
                                        emails                => [{value => $social_user_email}],
                                        provider              => 'google',
                                        provider_identity_uid => 'test_uid',
                                    }
                                },
                            },
                        },
                    },
                };
            });

        note "Successful social login without ONE TIME PASSWORD";
        $post->(
            $login_url,
            {
                app_id           => $app_id,
                type             => $login_type,
                connection_token => 'true'
            },
            {
                Authorization => "Bearer $jwt_token",
            })->status_is(200)->json_has('/tokens');

        # Updating social_user to is_totp_enabled
        $social_user->update_totp_fields(is_totp_enabled => 1);
        note "Missing ONE TIME PASSWORD";
        $post->(
            $login_url,
            {
                app_id            => $app_id,
                type              => $login_type,
                connection_token  => 'true',
                one_time_password => ''
            },
            {
                Authorization => "Bearer $jwt_token",
            })->status_is(400)->json_is('/error_code', 'MISSING_ONE_TIME_PASSWORD');

        note "Wrong ONE TIME PASSWORD";
        $post->(
            $login_url,
            {
                app_id            => $app_id,
                type              => $login_type,
                connection_token  => 'true',
                one_time_password => 'XyZxYz'
            },
            {
                Authorization => "Bearer $jwt_token",
            })->status_is(400)->json_is('/error_code', 'TFA_FAILURE');

        note "Successful social login with ONE TIME PASSWORD";
        $post->(
            $login_url,
            {
                app_id            => $app_id,
                type              => $login_type,
                connection_token  => 'true',
                one_time_password => $totp_value,
            },
            {
                Authorization => "Bearer $jwt_token",
            })->status_is(200)->json_has('/tokens');
    };
};

$api_mock->unmock_all;
$totp_mock->unmock_all;
done_testing()
