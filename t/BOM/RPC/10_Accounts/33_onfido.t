use strict;
use warnings;

use Test::MockModule;
use Test::More;
use BOM::RPC::v3::Services;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Token::API;
use Test::BOM::RPC::QueueClient;
use Test::Mojo;
use HTTP::Response;
use JSON::MaybeUTF8 qw(encode_json_utf8);

subtest 'onfido validation errors' => sub {
    subtest 'invalid postal code' => sub {
        my $payload = {
            error => {
                type    => 'validation_error',
                message => 'There was a validation error on this request',
                fields  => {
                    addresses => [{postcode => ['invalid postcode']},],
                },
            },
        };

        my $fake_http_response = HTTP::Response->new(422, 'Unprocessable Entity', [], encode_json_utf8($payload));

        my $onfido_mocker = Test::MockModule->new('BOM::RPC::v3::Services::Onfido');
        $onfido_mocker->mock(
            '_get_onfido_applicant',
            sub {
                return Future->fail(('422 something something', 'http', $fake_http_response));
            });

        my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $test_client->place_of_birth('br');
        $test_client->residence('br');
        $test_client->save;

        my $args = {
            service  => 'onfido',
            referrer => 'https://www.binary.com/'
        };
        my $m     = BOM::Platform::Token::API->new;
        my $token = $m->create_token($test_client->loginid, 'test token');

        my $c   = Test::BOM::RPC::QueueClient->new();
        my $res = $c->tcall(
            'service_token',
            {
                token => $token,
                args  => $args
            });

        is $res->{error}->{code}, 'InvalidPostalCode', 'Cannot create applicant due to invalid postal code';
    };

    subtest 'standard error response' => sub {
        my $payload = {
            error => {
                type    => 'validation_error',
                message => 'There was a validation error on this request',
                fields  => {
                    addresses => [{some_other_field => ['invalid something']},],
                },
            },
        };

        my $fake_http_response = HTTP::Response->new(422, 'Unprocessable Entity', [], encode_json_utf8($payload));

        my $onfido_mocker = Test::MockModule->new('BOM::RPC::v3::Services::Onfido');
        $onfido_mocker->mock(
            '_get_onfido_applicant',
            sub {
                return Future->fail(('422 something something', 'http', $fake_http_response));
            });

        my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $test_client->place_of_birth('br');
        $test_client->residence('br');
        $test_client->save;

        my $args = {
            service  => 'onfido',
            referrer => 'https://www.binary.com/'
        };
        my $m     = BOM::Platform::Token::API->new;
        my $token = $m->create_token($test_client->loginid, 'test token');

        my $c   = Test::BOM::RPC::QueueClient->new();
        my $res = $c->tcall(
            'service_token',
            {
                token => $token,
                args  => $args
            });

        is $res->{error}->{code}, 'ApplicantError', 'Generic applicant error';
    };
};

done_testing();
