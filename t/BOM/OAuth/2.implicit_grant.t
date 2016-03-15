use strict;
use warnings;
use Test::More;
use Test::Mojo;
use BOM::System::Password;
use BOM::Platform::User;
use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Database::Model::OAuth;

## init
my $oauth = BOM::Database::Model::OAuth->new;
$oauth->dbh->do("DELETE FROM oauth.user_scope_confirm");
$oauth->dbh->do("DELETE FROM oauth.access_token");
$oauth->dbh->do("DELETE FROM oauth.apps WHERE name='Test App'");
my $app = $oauth->create_app({
    name         => 'Test App',
    user_id      => 1,
    scopes       => ['read', 'trade'],
    redirect_uri => 'https://www.example.com/'
});
my $app_id = $app->{app_id};

my $t = Test::Mojo->new('BOM::OAuth');

$t = $t->get_ok("/authorize");
$t->json_is('/error', 'invalid_request')->json_like('/error_description', qr/missing app_id/);

$t = $t->get_ok("/authorize?app_id=XXX");
$t->json_like('/error_description', qr/valid app_id/);

$t = $t->get_ok("/authorize?app_id=$app_id");
is $t->tx->res->headers->location, '/login', 'redirect to /login';

## treat as logined b/c we do not have bom-web setup here
my $email     = 'abc@binary.com';
my $password  = 'jskjd8292922';
my $hash_pwd  = BOM::System::Password::hashpw($password);
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

my $token = BOM::Platform::SessionCookie->new(
    loginid => $cr_1,
    email   => $email,
)->token;
$t->ua->cookie_jar->add(
    Mojo::Cookie::Response->new(
        name   => 'login',
        value  => $token,
        domain => $t->tx->req->url->host,
        path   => '/'
    ));

# confirm_scopes
$t = $t->get_ok("/authorize?app_id=$app_id")->content_like(qr/confirm_scopes/);

my $csrftoken = $t->tx->res->dom->at('input[name=csrftoken]')->val;
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

## second time won't have confirm scopes
$t = $t->get_ok("/authorize?app_id=$app_id");
ok $t->tx->res->headers->location =~ 'https://www.example.com/', 'redirect to example';

done_testing();
