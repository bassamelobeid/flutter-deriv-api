use strict;
use warnings;

use Test::MockModule;
use Test::More;
use BOM::RPC::v3::Services;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Test::BOM::RPC::QueueClient;
use HTTP::Response;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use Test::Deep      qw( cmp_deeply );

use BOM::RPC::v3::Services::Nakala;

my $mock_http      = Test::MockModule->new('Net::Async::HTTP');
my $nakala_mock    = Test::MockModule->new('BOM::RPC::v3::Services::Nakala');
my $nakala_test_id = 12345;
$nakala_mock->mock(
    'nakala_id',
    sub {
        return $nakala_test_id;
    });

my $test_client        = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
my $client_token_admin = BOM::Platform::Token::API->new->create_token($test_client->loginid, 'test token', ['admin']);

subtest 'nakala request initialization' => sub {
    my $mock_config  = Test::MockModule->new('BOM::Config');
    my $dummy_config = {
        base_url => 'dummy.com',
        mgr_name => 'dummy',
        mgr_pass => 'dummy_pass'
    };
    $nakala_mock->mock(
        'config',
        sub {
            return $dummy_config;
        });
    my $nakala  = BOM::RPC::v3::Services::Nakala->new((client => $test_client));
    my $req     = $nakala->create_auth_request;
    my $payload = {
        id      => undef,
        method  => 'la.auth',
        jsonrpc => '2.0',
        params  => {wa_login => $nakala_test_id}};
    my $headers = {
        'la_type'     => 0,
        'ManagerPass' => 'dummy_pass',
        'ManagerName' => 'dummy',
        'la_login'    => $nakala_test_id
    };

    is $req->{url}, $dummy_config->{base_url} . '/dx', 'host is correct';
    cmp_deeply decode_json_utf8($req->{payload}), $payload, 'payload is correct';
    cmp_deeply $req->{headers},                   $headers, 'headers is correct';
};

subtest 'generate token' => sub {
    my $response_data;
    $mock_http->mock(
        POST => sub {
            my $headers  = HTTP::Headers->new('Content-Type', 'application/json');
            my $response = HTTP::Response->new(200, 'Dummy', $headers, ref $response_data ? encode_json_utf8($response_data) : $response_data);
            return Future->done($response);
        });
    my $general_error = {
        error => {
            message_to_client => "Cannot generate token for $nakala_test_id.",
            code              => 'NakalaTokenGenerationError'
        }};

    my @test_cases = ({
            response => {
                jsonrpc => "2.0",
                id      => "123",
                method  => "la.auth",
                result  => {
                    AccessToken => 'dummy_token',
                    AccessValid => 900,
                    ttl         => 900
                }
            },
            result => $general_error,
            msg    => 'return error if has access token but no account found'
        },
        {
            response => 'dummy response',
            result   => $general_error,
            msg      => 'return error if not json'
        },
        {
            response => {
                jsonrpc => "2.0",
                id      => "123",
                method  => "la.auth",
                result  => {
                    AccessToken => 'dummy_token',
                    AccessValid => 900,
                    ttl         => 900,
                    user        => {
                        id       => 1,
                        la_login => $nakala_test_id
                    }}
            },
            result => {nakala => {token => 'dummy_token'}},
            msg    => 'return token when account found'
        },
        {
            response => {
                jsonrpc => "2.0",
                id      => "123",
                method  => "la.auth",
                error   => {
                    code    => 56,
                    message => 'rpc error',
                    data    => {}}
            },
            result => $general_error,
            msg    => 'return error when api return error'
        },
    );

    my $c = Test::BOM::RPC::QueueClient->new();
    for my $test_case (@test_cases) {
        $response_data = $test_case->{response};
        my $res = $c->tcall(
            'service_token',
            {
                token => $client_token_admin,
                args  => {service => 'nakala'}});

        cmp_deeply($res, $test_case->{result}, $test_case->{msg});
    }

    #faild response
    $mock_http->mock(
        POST => sub {
            return Future->fail(1);
        });
    my $res = $c->tcall(
        'service_token',
        {
            token => $client_token_admin,
            args  => {service => 'nakala'}});

    cmp_deeply($res, $general_error, 'return error correctly');

};

done_testing();
