use strict;
use warnings;
use Test::More;
use Test::Mojo;
use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Database::Model::OAuth;

ok(1);
diag "we do not support auth_code.";
done_testing();
exit;

## clear
BOM::Database::Model::OAuth->new->dbh->do("DELETE FROM oauth.user_scope_confirm");

my $t = Test::Mojo->new('BOM::OAuth');

$t = $t->get_ok("/authorize");
$t->json_is('/error', 'invalid_request')->json_like('/error_description', qr/missing app_id/);

$t = $t->get_ok("/authorize?app_id=binarycom");
$t->json_is('/error', 'invalid_request')->json_like('/error_description', qr/missing redirect_uri/);

$t = $t->get_ok("/authorize?app_id=XXX&redirect_uri=http://localhost/");
ok $t->tx->res->headers->location =~ 'invalid_app', 'redirect to localhost with invalid_app';

$t = $t->get_ok("/authorize?app_id=binarycom&redirect_uri=http://www.example.com/");
ok $t->tx->res->headers->location =~ 'invalid_redirect_uri', 'redirect with invalid_redirect_uri';

$t = $t->get_ok("/authorize?app_id=binarycom&redirect_uri=http://localhost/");
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
$t = $t->get_ok("/authorize?app_id=binarycom&redirect_uri=http://localhost/")->content_like(qr/confirm_scopes/);

my $csrftoken = $t->tx->res->dom->at('input[name=csrftoken]')->val;
ok $csrftoken, 'csrftoken is there';

$t->post_ok(
    "/authorize?app_id=binarycom&redirect_uri=http://localhost/" => form => {
        confirm_scopes => 1,
        csrftoken      => $csrftoken
    });
ok $t->tx->res->headers->location =~ 'http://localhost/', 'redirect to localhost';
my ($code) = ($t->tx->res->headers->location =~ /code=(.*?)$/);
ok $code, 'got auth code';

## second time won't have confirm scopes
$t = $t->get_ok("/authorize?app_id=binarycom&redirect_uri=http://localhost/");
ok $t->tx->res->headers->location =~ 'http://localhost/', 'redirect to localhost';

## but new scope will require confirm_scopes again
$t = $t->get_ok("/authorize?app_id=binarycom&redirect_uri=http://localhost/&scope=trade")->content_like(qr/confirm_scopes/);

## now we come to access_token
$t = $t->post_ok('/access_token');
$t->json_is('/error', 'invalid_request')->json_like('/error_description', qr/missing app_id/);

$t = $t->post_ok('/access_token?app_id=binarycom');
$t->json_is('/error', 'invalid_request')->json_like('/error_description', qr/missing valid grant_type/);

$t = $t->post_ok('/access_token?app_id=binarycom&grant_type=authorization_code');
$t->json_is('/error', 'invalid_request')->json_like('/error_description', qr/missing code/);

$t = $t->post_ok("/access_token?app_id=binarycom&grant_type=authorization_code&code=$code");
$t->json_is('/error', 'invalid_app');

$t = $t->post_ok("/access_token?app_id=binarycom&app_secret=WrongSEC&grant_type=authorization_code&code=$code");
$t->json_is('/error', 'invalid_app');

$t = $t->post_ok("/access_token?app_id=binarycom&app_secret=bin2Sec&grant_type=authorization_code&code=$code");
my $json          = $t->tx->res->json;
my $refresh_token = $json->{refresh_token};
ok $json->{refresh_token}, 'access token ok';
ok $json->{access_token},  'access token ok';

$t = $t->post_ok("/access_token?app_id=binarycom&app_secret=bin2Sec&grant_type=authorization_code&code=$code");
$t->json_is('/error', 'invalid_grant');    # can not re-use

## try refresh token
$t    = $t->post_ok("/access_token?app_id=binarycom&app_secret=bin2Sec&grant_type=refresh_token&refresh_token=$refresh_token");
$json = $t->tx->res->json;
ok $json->{refresh_token}, 'refresh token ok';
ok $json->{access_token},  'refresh token ok';

$t = $t->post_ok("/access_token?app_id=binarycom&app_secret=bin2Sec&grant_type=refresh_token&refresh_token=$refresh_token");
$t->json_is('/error', 'invalid_grant');    # can not re-use

done_testing();
