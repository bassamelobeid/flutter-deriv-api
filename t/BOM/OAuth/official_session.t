use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::MockModule;

use Test::Deep;

use BOM::Database::Model::OAuth;
use BOM::User::Password;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $oauth = BOM::Database::Model::OAuth->new;
my $app;

sub _generate_app_id {
    my ($name, $redirect_uri, $scopes) = @_;
    my $oauth = BOM::Database::Model::OAuth->new;
    $oauth->dbic->dbh->do("DELETE FROM oauth.user_scope_confirm");
    $oauth->dbic->dbh->do("DELETE FROM oauth.access_token");
    $oauth->dbic->dbh->do("DELETE FROM oauth.apps WHERE name='$name'");
    $app = $oauth->create_app({
        name         => $name,
        user_id      => 1,
        scopes       => $scopes,
        redirect_uri => $redirect_uri
    });
    $app->{app_id};
}

#mock Mojo::Controller
my $mock_mojo      = Test::MockModule->new('Mojolicious::Controller');
my $signed_cookies = {};
$mock_mojo->mock(
    signed_cookie => sub {
        my ($self, $cookie_name, $cookie_data, $cookie_settings) = @_;
        $signed_cookies->{$cookie_name} = {
            data     => $cookie_data,
            settings => $cookie_settings
        } if defined $cookie_data;

        $mock_mojo->original('signed_cookie')->(@_);
    });

## create test user to login
my $email     = 'abc@binary.com';
my $password  = 'jskjd8292922';
my $hash_pwd  = BOM::User::Password::hashpw($password);
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client_cr->email($email);
$client_cr->save;
my $cr_loginid = $client_cr->loginid;
my $user       = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->add_client($client_cr);

my @official_apps = ();
my $model_mock    = Test::MockModule->new('BOM::Database::Model::OAuth');
$model_mock->mock(
    'is_official_app',
    sub {
        shift;
        my $app = shift;
        return grep { $_ eq $app } @official_apps;
    });
my $official_app_id     = _generate_app_id('Test App',     'https://www.example.com/', ['read', 'trade', 'admin']);
my $non_official_app_id = _generate_app_id('Testing App2', 'https://www.example.com/', ['read', 'trade']);
push @official_apps, $official_app_id;

$model_mock->mock(
    'is_scope_confirmed',
    sub {
        return 1;
    });

my $t = Test::Mojo->new('BOM::OAuth');

my $mock_oauth_controller = Test::MockModule->new('BOM::OAuth::O');
$mock_oauth_controller->mock(
    'csrf_token' => sub {
        return 'csrf_token';
    });

$t->post_ok(
    "/authorize?app_id=$official_app_id" => form => {
        login      => 1,
        email      => $email,
        csrf_token => 'csrf_token'
    });

subtest 'official session login - official app' => sub {
    my $stash;
    $t->app->hook(after_dispatch => sub { $stash = shift->stash });

    subtest 'official session login frist login - type Basic' => sub {
        $t->post_ok(
            "/authorize?app_id=$official_app_id" => form => {
                login      => 1,
                email      => $email,
                password   => $password,
                csrf_token => 'csrf_token'
            })->status_is(302);

        ok(exists $signed_cookies->{_osid}, 'official session is set in the session data');
        my $app_id_cookie = '_osid_' . $official_app_id;
        ok(exists $signed_cookies->{$app_id_cookie}, 'official session is set in the session data');
    };

    subtest 'official session login - type official_session' => sub {
        my $mocked_session_store = Test::MockModule->new('BOM::OAuth::SessionStore');
        $mocked_session_store->mock(
            'new',
            sub {
                return $stash->{'session_store'};
            });

        $t->get_ok("/authorize?app_id=$official_app_id")->status_is(302);

        ok $t->tx->res->headers->location =~ 'https://www.example.com/', 'redirected without providing password';
        my ($code) = ($t->tx->res->headers->location =~ /token1=(.*?)$/);
        ok $code, 'got access code';

        $mocked_session_store->unmock_all;
        $signed_cookies = {};
    };
};

subtest 'official session login - non official app' => sub {
    my $stash;
    $t->app->hook(after_dispatch => sub { $stash = shift->stash });

    subtest 'official session login frist login - type Basic' => sub {

        $t->post_ok(
            "/authorize?app_id=$non_official_app_id" => form => {
                login      => 1,
                email      => $email,
                password   => $password,
                csrf_token => 'csrf_token'
            })->status_is(302);

        ok $t->tx->res->headers->location =~ 'https://www.example.com/', 'redirect to example';

        ok(!exists $signed_cookies->{_osid}, 'No _osid cookiefor non official app in the session');
        my $app_id_cookie = '_osid_' . $non_official_app_id;
        ok(!exists $signed_cookies->{$app_id_cookie}, 'No _osid_app cookie added for non official app');
    };

    subtest 'official session login for non official apps' => sub {
        my $mocked_session_store = Test::MockModule->new('BOM::OAuth::SessionStore');
        $mocked_session_store->mock(
            'new',
            sub {
                return $stash->{'session_store'};
            });

        $t->get_ok("/authorize?app_id=$non_official_app_id")->status_is(200);

        $t->content_like(qr/login/);
    };

};

done_testing();
