use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use BOM::Platform::Password;
use BOM::Platform::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Database::Model::OAuth;

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
    my $hash_pwd  = BOM::Platform::Password::hashpw($password);
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
    my $vr_1 = $client_vr->loginid;
    my $cr_1 = $client_cr->loginid;
    my $user = BOM::Platform::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->save;
    $user->add_loginid({loginid => $vr_1});
    $user->add_loginid({loginid => $cr_1});
    $user->save;
}

# mock domain_name to suppress warnings
my $mocked_request = Test::MockModule->new('BOM::Platform::Context::Request');
$mocked_request->mock('domain_name', 'www.binaryqa.com');

my $t = Test::Mojo->new('BOM::OAuth');

$t = $t->get_ok("/authorize");
$t->json_is('/error', 'invalid_request')->json_like('/error_description', qr/missing app_id/);

$t = $t->get_ok("/authorize?app_id=9999999");
$t->json_like('/error_description', qr/valid app_id/);

$t = $t->get_ok("/authorize?app_id=$app_id")->content_like(qr/login/);

my $csrftoken = $t->tx->res->dom->at('input[name=csrftoken]')->val;
ok $csrftoken, 'csrftoken is there';
$t->post_ok(
    "/authorize?app_id=$app_id" => form => {
        login     => 1,
        email     => $email,
        password  => $password,
        csrftoken => $csrftoken
    });

# confirm_scopes after login
$t = $t->content_like(qr/confirm_scopes/);

$csrftoken = $t->tx->res->dom->at('input[name=csrftoken]')->val;
ok $csrftoken, 'csrftoken is there';

$t->post_ok(
    "/authorize?app_id=$app_id" => form => {
        confirm_scopes => 1,
        csrftoken      => $csrftoken
    });

ok $t->tx->res->headers->location =~ 'https://www.example.com/', 'redirect to example';
my ($code) = ($t->tx->res->headers->location =~ /token1=(.*?)$/);
ok $code, 'got access code';
($code) = ($t->tx->res->headers->location =~ /token2=(.*?)$/);
ok $code, 'got access code for another loginid';

## second time we'll see login again and POST will not require confirm scopes
$t = $t->get_ok("/authorize?app_id=$app_id")->content_like(qr/login/);

$csrftoken = $t->tx->res->dom->at('input[name=csrftoken]')->val;
$t->post_ok(
    "/authorize?app_id=$app_id" => form => {
        login     => 1,
        email     => $email,
        password  => $password,
        csrftoken => $csrftoken
    });

ok $t->tx->res->headers->location =~ 'https://www.example.com/', 'redirect to example w/o confirm scopes';

done_testing();
