use strict;
use warnings;
use Test::More;
use Test::Mojo;
use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;

my $t = Test::Mojo->new('BOM::OAuth');

$t = $t->get_ok("/authorize");
$t->json_is('/error', 'invalid_request')->json_like('/error_description', qr/missing client_id/);

$t = $t->get_ok("/authorize?client_id=binarycom");
$t->json_is('/error', 'invalid_request')->json_like('/error_description', qr/missing redirect_uri/);

$t = $t->get_ok("/authorize?client_id=XXX&redirect_uri=http://localhost/");
ok $t->tx->res->headers->location =~ 'invalid_client', 'redirect to localhost with invalid_client';

$t = $t->get_ok("/authorize?client_id=binarycom&redirect_uri=http://localhost/");
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

$t = $t->get_ok("/authorize?client_id=binarycom&redirect_uri=http://localhost/");
ok $t->tx->res->headers->location =~ 'http://localhost/', 'redirect to localhost';
my ($code) = ($t->tx->res->headers->location =~ /code=(.*?)$/);
ok $code, 'got auth code';

## now we come to access_token
$t = $t->post_ok('/access_token');
$t->json_is('/error', 'invalid_request')->json_like('/error_description', qr/missing client_id/);

$t = $t->post_ok('/access_token?client_id=binarycom');
$t->json_is('/error', 'invalid_request')->json_like('/error_description', qr/missing valid grant_type/);

$t = $t->post_ok('/access_token?client_id=binarycom&grant_type=authorization_code');
$t->json_is('/error', 'invalid_request')->json_like('/error_description', qr/missing code/);

$t = $t->post_ok("/access_token?client_id=binarycom&grant_type=authorization_code&code=$code");
$t->json_is('/error', 'invalid_client');

$t = $t->post_ok("/access_token?client_id=binarycom&client_secret=WrongSEC&grant_type=authorization_code&code=$code");
$t->json_is('/error', 'invalid_client');

$t = $t->post_ok("/access_token?client_id=binarycom&client_secret=bin2Sec&grant_type=authorization_code&code=$code");
my $json          = $t->tx->res->json;
my $refresh_token = $json->{refresh_token};
ok $json->{refresh_token}, 'access token ok';
ok $json->{access_token},  'access token ok';

$t = $t->post_ok("/access_token?client_id=binarycom&client_secret=bin2Sec&grant_type=authorization_code&code=$code");
$t->json_is('/error', 'invalid_grant');    # can not re-use

## try refresh token
$t    = $t->post_ok("/access_token?client_id=binarycom&client_secret=bin2Sec&grant_type=refresh_token&refresh_token=$refresh_token");
$json = $t->tx->res->json;
ok $json->{refresh_token}, 'refresh token ok';
ok $json->{access_token},  'refresh token ok';

$t = $t->post_ok("/access_token?client_id=binarycom&client_secret=bin2Sec&grant_type=refresh_token&refresh_token=$refresh_token");
$t->json_is('/error', 'invalid_grant');    # can not re-use

done_testing();
