use strict;
use warnings;
use Test::More;
use Test::Mojo;
use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Database::Model::OAuth;

## clear
BOM::Database::Model::OAuth->new->dbh->do("DELETE FROM oauth.user_scope_confirm");

my $t = Test::Mojo->new('BOM::OAuth');

$t = $t->get_ok("/authorize");
$t->json_is('/error', 'invalid_request')->json_like('/error_description', qr/missing app_id/);

$t = $t->get_ok("/authorize?app_id=binarycom");
$t->json_is('/error', 'invalid_request')->json_like('/error_description', qr/missing redirect_uri/);

$t = $t->get_ok("/authorize?app_id=XXX&redirect_uri=https://www.binary.com/&response_type=token");
ok $t->tx->res->headers->location =~ 'invalid_app', 'redirect to localhost with invalid_app';

$t = $t->get_ok("/authorize?app_id=binarycom&redirect_uri=http://www.example.com/&response_type=token");
ok $t->tx->res->headers->location =~ 'invalid_redirect_uri', 'redirect with invalid_redirect_uri';

$t = $t->get_ok("/authorize?app_id=binarycom&redirect_uri=https://www.binary.com/&response_type=token");
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
$t = $t->get_ok("/authorize?app_id=binarycom&redirect_uri=https://www.binary.com/&response_type=token")->content_like(qr/confirm_scopes/);

my $csrftoken = $t->tx->res->dom->at('input[name=csrftoken]')->val;
ok $csrftoken, 'csrftoken is there';

$t->post_ok(
    "/authorize?app_id=binarycom&redirect_uri=https://www.binary.com/&response_type=token" => form => {
        confirm_scopes => 1,
        csrftoken      => $csrftoken
    });
ok $t->tx->res->headers->location =~ 'https://www.binary.com/', 'redirect to localhost';
my ($code) = ($t->tx->res->headers->location =~ /token=(.*?)$/);
ok $code, 'got access code';

## second time won't have confirm scopes
$t = $t->get_ok("/authorize?app_id=binarycom&redirect_uri=https://www.binary.com/&response_type=token");
ok $t->tx->res->headers->location =~ 'https://www.binary.com/', 'redirect to localhost';

## but new scope will require confirm_scopes again
$t = $t->get_ok("/authorize?app_id=binarycom&redirect_uri=https://www.binary.com/&scope=trade&response_type=token")->content_like(qr/confirm_scopes/);

done_testing();
