use strict;
use warnings;
use Test::More;
use Test::Mojo;
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

$t = $t->get_ok("/authorize?app_id=XXX&response_type=token");
$t->json_like('/error_description', qr/valid app_id/);

$t = $t->get_ok("/authorize?app_id=$app_id&response_type=token");
is $t->tx->res->headers->location, '/login', 'redirect to /login';

## treat as logined b/c we do not have bom-web setup here
my $token = BOM::Platform::SessionCookie->new(
    loginid => "CR2002",
    email   => 'sy@regentmarkets.com',
)->token;
$t->ua->cookie_jar->add(
    Mojo::Cookie::Response->new(
        name   => 'login',
        value  => $token,
        domain => $t->tx->req->url->host,
        path   => '/'
    ));

# confirm_scopes
$t = $t->get_ok("/authorize?app_id=$app_id&response_type=token")->content_like(qr/confirm_scopes/);

my $csrftoken = $t->tx->res->dom->at('input[name=csrftoken]')->val;
ok $csrftoken, 'csrftoken is there';

$t->post_ok(
    "/authorize?app_id=$app_id&response_type=token" => form => {
        confirm_scopes => 1,
        csrftoken      => $csrftoken
    });
ok $t->tx->res->headers->location =~ 'https://www.example.com/', 'redirect to example';
my ($code) = ($t->tx->res->headers->location =~ /token=(.*?)$/);
ok $code, 'got access code';

## second time won't have confirm scopes
$t = $t->get_ok("/authorize?app_id=$app_id&response_type=token");
ok $t->tx->res->headers->location =~ 'https://www.example.com/', 'redirect to example';

done_testing();
