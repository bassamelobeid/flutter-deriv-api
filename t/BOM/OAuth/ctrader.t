use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::MockModule;
use Test::Warn;
use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Digest::SHA1                               qw(sha1_hex);

use BOM::OAuth::CTrader;
use BOM::TradingPlatform::CTrader;

my $t = Test::Mojo->new('BOM::OAuth');

my $api_mock     = Test::MockModule->new('BOM::OAuth::CTrader');
my $api_password = 'some_password';
$api_mock->mock(get_api_passwords => sha1_hex($api_password));

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
BOM::User->create(
    email    => $client->email,
    password => 'test'
)->add_client($client);

my @mocked_ctrader_logins = qw(CTR1);
my $user_mock             = Test::MockModule->new('BOM::User');
$user_mock->mock(
    ctrade_loginids => sub { return @mocked_ctrader_logins },
);

my $ctrader_mock = Test::MockModule->new('BOM::TradingPlatform::CTrader');
$ctrader_mock->mock(
    get_ctid_userid => 1,
);

subtest 'crmApiToken' => sub {
    my $url = '/api/v1/verify';

    note "No password provided";
    $t->post_ok('/api/v1/ctrader/oauth2/crmApiToken' => 'some_body')->status_is(401)->json_is('/error_code', 'INVALID_PASSWORD');

    note "Wrong password provided";
    $t->post_ok('/api/v1/ctrader/oauth2/crmApiToken' => json => {password => 'wrong_password'})->status_is(401)
        ->json_is('/error_code', 'INVALID_PASSWORD');

    note "Correct password provided";
    my $resp = $t->post_ok('/api/v1/ctrader/oauth2/crmApiToken' => json => {password => $api_password})->status_is(200)
        ->json_like('/crmApiToken' => qr/^[\w-]*(?:\.[\w-]*){2}$/);
};

subtest 'onetime authorize' => sub {
    note "Get API token";
    my $token = $t->post_ok('/api/v1/ctrader/oauth2/crmApiToken' => json => {password => $api_password})->tx->res->json->{crmApiToken};

    note "Making request with no API token";
    $t->post_ok('/api/v1/ctrader/oauth2/onetime/authorize' => 'some_body')->status_is(401)->json_is('/error_code', 'INVALID_TOKEN');

    note "Making request with incorrent API token";
    $t->post_ok('/api/v1/ctrader/oauth2/onetime/authorize?token=some_token' => 'some_body')->status_is(401)->json_is('/error_code', 'INVALID_TOKEN');

    note "Making request with correct API token";
    $t->post_ok('/api/v1/ctrader/oauth2/onetime/authorize?token=' . $token => 'some_body')->status_is(400)
        ->json_is('/error_code', 'INVALID_OTT_TOKEN');

    note "Making request with invalid one-time token";
    $t->post_ok('/api/v1/ctrader/oauth2/onetime/authorize?token=' . $token, json => {code => 'Invalid_OTT'})->status_is(400)
        ->json_is('/error_code', 'INVALID_OTT_TOKEN');

    # Generate one time token
    my $ctrader = BOM::TradingPlatform::CTrader->new(client => $client);
    my $ott     = $ctrader->generate_login_token('Mozzila 5.0');

    note "Making request with valid one-time token";
    $t->post_ok('/api/v1/ctrader/oauth2/onetime/authorize?token=' . $token, json => {code => $ott})->status_is(200)->json_is('/userId', 1)
        ->json_like('/accessToken', qr/ct\d+-\w+/);

    note "Trying to use same token twice ";
    $t->post_ok('/api/v1/ctrader/oauth2/onetime/authorize?token=' . $token, json => {code => $ott})->status_is(400)
        ->json_is('/error_code', 'INVALID_OTT_TOKEN');
};

subtest 'authorize' => sub {
    note "Get API token";
    my $token = $t->post_ok('/api/v1/ctrader/oauth2/crmApiToken' => json => {password => $api_password})->tx->res->json->{crmApiToken};

    note "Making request with no API token";
    $t->post_ok('/api/v1/ctrader/oauth2/authorize' => 'some_body')->status_is(401)->json_is('/error_code', 'INVALID_TOKEN');

    note "Making request with incorrent API token";
    $t->post_ok('/api/v1/ctrader/oauth2/authorize?token=some_token' => 'some_body')->status_is(401)->json_is('/error_code', 'INVALID_TOKEN');

    note "Making request with correct API token";
    $t->post_ok('/api/v1/ctrader/oauth2/authorize?token=' . $token => 'some_body')->status_is(400)->json_is('/error_code', 'INVALID_ACCESS_TOKEN');

    note "Making request with invalid access token";
    $t->post_ok('/api/v1/ctrader/oauth2/authorize?token=' . $token => json => {accessToken => 'Invalid_token'})->status_is(400)
        ->json_is('/error_code', 'INVALID_ACCESS_TOKEN');

    #Acquare access token.
    my $ctrader      = BOM::TradingPlatform::CTrader->new(client => $client);
    my $ott          = $ctrader->generate_login_token('Mozzila 5.0');
    my $access_token = $t->post_ok('/api/v1/ctrader/oauth2/onetime/authorize?token=' . $token, json => {code => $ott})->tx->res->json->{accessToken};

    note "Making request with valid access token";
    $t->post_ok('/api/v1/ctrader/oauth2/authorize?token=' . $token => json => {accessToken => $access_token})->status_is(200)->json_is('/userId', 1);

    note "Making request with valid access token multiple times working fine as well";
    $t->post_ok('/api/v1/ctrader/oauth2/authorize?token=' . $token => json => {accessToken => $access_token})->status_is(200)->json_is('/userId', 1);
};

subtest generate_onetime_token => sub {
    # Check that API endpoing returns correct error.
    $t->post_ok('/api/v1/ctrader/oauth2/onetime/generate')->status_is(501)->json_is('/error_code', 'NOT_IMPLEMENTED');
};

done_testing();

