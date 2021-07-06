use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::MockModule;

use Mojo::URL;
use URI::Escape;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::User::Password;
use BOM::User;

my $t      = Test::Mojo->new('BOM::OAuth');
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

my $tests = [{
        platform        => 'p2p',
        official        => 1,
        in_session      => 1,
        scope_confirmed => 1,
    },
    {
        platform        => 'p2p',
        official        => 1,
        in_session      => 1,
        scope_confirmed => 0,
    },
    {
        platform        => 'p3p',
        official        => 0,
        in_session      => 1,
        scope_confirmed => 1
    },
    {
        platform        => 'p3p',
        official        => 0,
        in_session      => 1,
        scope_confirmed => 0
    },
    {
        platform        => undef,
        official        => 1,
        in_session      => 0,
        scope_confirmed => 1
    },
    {
        platform        => undef,
        official        => 1,
        in_session      => 0,
        scope_confirmed => 0
    },
    {
        platform        => undef,
        official        => 0,
        in_session      => 0,
        scope_confirmed => 1
    },
    {
        platform        => undef,
        official        => 0,
        in_session      => 0,
        scope_confirmed => 0
    },
    {
        platform        => '--- trying hard $$$',
        official        => 0,
        in_session      => 0,
        scope_confirmed => 0,
        invalid         => 1,
    },
    {
        platform        => '--- trying hard $$$',
        official        => 1,
        in_session      => 0,
        scope_confirmed => 0,
        invalid         => 1,
    },
    {
        platform        => '--- trying hard $$$',
        official        => 0,
        in_session      => 0,
        scope_confirmed => 1,
        invalid         => 1,
    },
];

my $email    = 'platform+param@binary.com';
my $password = 'Abcd1234';

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

my $omock   = Test::MockModule->new('BOM::OAuth::O');
my $session = {};
my $redirect_uri;

$omock->mock(
    'session',
    sub {
        my (undef, @args) = @_;

        $session = {$session->%*, @args} if scalar @args == 2;

        return $omock->original('session')->(@_);
    });

$omock->mock(
    'redirect_to',
    sub {
        (undef, $redirect_uri) = @_;
        return $omock->original('redirect_to')->(@_);
    });

my $model_mock = Test::MockModule->new('BOM::Database::Model::OAuth');
my $is_official_app;
my $is_scope_confirmed;

$model_mock->mock(
    'is_official_app',
    sub {
        return $is_official_app;
    });

$model_mock->mock(
    'is_scope_confirmed',
    sub {
        return $is_scope_confirmed;
    });

for ($tests->@*) {
    my ($platform, $in_session, $official, $scope_confirmed, $invalid) = @{$_}{qw/platform in_session official scope_confirmed invalid/};
    $is_official_app    = $official;
    $is_scope_confirmed = $scope_confirmed;

    my $title =
          'Platform is '
        . ($platform // 'not given')
        . ($official        ? ' official'          : ' unofficial')
        . ($scope_confirmed ? ' + scope confirmed' : ' + scope not confirmed');

    subtest $title => sub {
        $session      = {};
        $redirect_uri = undef;
        $t            = $t->reset_session;

        my $url = "/authorize?app_id=$app_id";

        $platform = uri_escape($platform) if $platform;
        $url .= "&platform=$platform"     if $platform;
        $t = $t->get_ok($url)->content_like(qr/login/);

        is $session->{platform}, $platform, 'Defined platform in session' if $in_session;
        ok !$session->{platform}, 'Undefined platform not in session' unless $in_session;

        my $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
        my $res        = $t->post_ok(
            $url => form => {
                login      => 1,
                email      => $email,
                password   => $password,
                csrf_token => $csrf_token
            });

        if ($official || $scope_confirmed) {
            my $uri = Mojo::URL->new($t->tx->res->headers->header('location'));

            if ($platform && !$invalid) {
                is $uri->query->param('platform'), $platform, 'Expected platform param passed into the redirection';
            } else {
                ok !$uri->query->param('platform'), 'No platform or invalid platform given';
            }

            is $redirect_uri, $uri, 'Expected redirect URI';
        } else {
            ok !$redirect_uri, 'No redirect for unofficial app or scope not confirmed';
        }
    };
}

done_testing()
