use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use BOM::User::Password;
use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Database::Model::OAuth;
use BOM::Config::Runtime;
use Mojo::Base 'Mojolicious::Controller';
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

## create test user to login
my $email    = 'abc@binary.com';
my $password = 'jskjd8292922';
{
    my $hash_pwd  = BOM::User::Password::hashpw($password);
    my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_vr->email($email);
    $client_vr->save;
    $client_cr->email($email);
    $client_cr->save;
    my $user = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->add_client($client_vr);
    $user->add_client($client_cr);
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

$t = $t->get_ok("/authorize");
$t->json_is('/error', 'invalid_request')->json_like('/error_description', qr/missing app_id/);

# "١" is Arabic digit 1
$t = $t->get_ok("/authorize?app_id=١");
$t->json_is('/error', 'invalid_request')->json_like('/error_description', qr/missing valid app_id/);

$t = $t->get_ok("/authorize?app_id=9999999");
$t->json_like('/error_description', qr/valid app_id/);

$t = $t->get_ok("/authorize?app_id=$app_id")->content_like(qr/login/);

my $csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
ok $csrf_token, 'csrf_token is there';

BOM::Config::Runtime->instance->app_config->system->suspend->all_logins(1);

$t->post_ok(
    "/authorize?app_id=$app_id" => form => {
        login      => 1,
        email      => $email,
        password   => $password,
        csrf_token => $csrf_token
    });

$t = $t->content_like(qr/Login to this account has been temporarily disabled due to system maintenance/);

BOM::Config::Runtime->instance->app_config->system->suspend->all_logins(0);

$t = $t->get_ok("/authorize?app_id=$app_id")->content_like(qr/login/);

$csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
ok $csrf_token, 'csrf_token is there';

my $mock_history = Test::MockModule->new('BOM::User');
$mock_history->mock(
    'get_last_successful_login_history' => sub {
        return {"environment" => "IP=1.1.1.1 IP_COUNTRY=1.1.1.1 User_AGENT=ABC LANG=AU"};
    });

$t->post_ok(
    "/authorize?app_id=$app_id" => form => {
        login      => 1,
        email      => $email,
        password   => $password,
        csrf_token => $csrf_token
    });

# confirm_scopes after login
$t = $t->content_like(qr/confirm_scopes/);

$csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
ok $csrf_token, 'csrf_token is there';

$t->post_ok(
    "/authorize?app_id=$app_id" => form => {
        confirm_scopes => 1,
        csrf_token     => $csrf_token
    });

ok $t->tx->res->headers->location =~ 'https://www.example.com/', 'redirect to example';
my ($code) = ($t->tx->res->headers->location =~ /token1=(.*?)$/);
ok $code, 'got access code';
($code) = ($t->tx->res->headers->location =~ /token2=(.*?)$/);
ok $code, 'got access code for another loginid';

my $mocked_mojo_cont = Test::MockModule->new('Mojolicious::Controller');
my $sessions_hash    = {};
$mocked_mojo_cont->mock(
    'session',
    sub {
        my $self = shift;

        my $stash = $self->stash;
        $self->app->sessions->load($self) unless exists $stash->{'mojo.active_session'};

        # Hash
        my $session = $stash->{'mojo.session'} ||= {};
        return $session unless @_;

        # Get
        return $session->{$_[0]} unless @_ > 1 || ref $_[0];

        # Set
        my $values = ref $_[0] ? $_[0] : {@_};
        @$session{keys %$values}       = values %$values;
        @$sessions_hash{keys %$values} = values %$values;
        return $self;
    });
## second time we'll see login again and POST will not require confirm scopes
$t = $t->get_ok("/authorize?app_id=$app_id")->content_like(qr/login/);

$csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
$t->post_ok(
    "/authorize?app_id=$app_id" => form => {
        login           => 1,
        email           => $email,
        password        => $password,
        csrf_token      => $csrf_token,
        affiliate_token => 'eU5Z1WAL-BPPj8EvNdDvbWNd7ZgqdRLk'
    });

ok $t->tx->res->headers->location =~ 'https://www.example.com/', 'redirect to example w/o confirm scopes';
#token validated & session set
ok $sessions_hash->{myaffiliates_token} =~ 'eU5Z1WAL-BPPj8EvNdDvbWNd7ZgqdRLk', 'affiliate_token  containing - validated & session set';
#reset session hash
$sessions_hash = {};
$t             = $t->get_ok("/authorize?app_id=$app_id")->content_like(qr/login/);

$csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
$t->post_ok(
    "/authorize?app_id=$app_id" => form => {
        login           => 1,
        email           => $email,
        password        => $password,
        csrf_token      => $csrf_token,
        affiliate_token => 'eU5Z1WAL_BPPj8EvNdDvbWNd7ZgqdRLk'
    });
#token validated & session set
ok $sessions_hash->{myaffiliates_token} =~ 'eU5Z1WAL_BPPj8EvNdDvbWNd7ZgqdRLk', 'affiliate_token containing _  validated & session set';

#reset session hash
$sessions_hash = {};
$t             = $t->get_ok("/authorize?app_id=$app_id")->content_like(qr/login/);

$csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
$t->post_ok(
    "/authorize?app_id=$app_id" => form => {
        login           => 1,
        email           => $email,
        password        => $password,
        csrf_token      => $csrf_token,
        affiliate_token => 'eU5Z1WAL_BPPj8EvNdDvbWNd7ZgqdRLk3'
    });
#token validated & session set
is $sessions_hash->{myaffiliates_token}, undef, 'affiliate_token length > 32 characters so session not set';

#reset session hash
$sessions_hash = {};
$t             = $t->get_ok("/authorize?app_id=$app_id")->content_like(qr/login/);

$csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->val;
$t->post_ok(
    "/authorize?app_id=$app_id" => form => {
        login           => 1,
        email           => $email,
        password        => $password,
        csrf_token      => $csrf_token,
        affiliate_token => 'eU5Z1WAL_BPPj8EvNdDvbWNd7ZgqdRL#'
    });
#token validated & session set
is $sessions_hash->{myaffiliates_token}, undef, 'affiliate_token having invalid characters so session not set';
$mocked_mojo_cont->unmock_all();

done_testing();
