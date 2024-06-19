use strict;
use warnings;

use Test::MockModule;
use Test::More;
use BOM::RPC::v3::Services;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Platform::Token::API;
use Test::BOM::RPC::QueueClient;
use Test::Mojo;
use Test::Deep;
use HTTP::Response;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use constant ONFIDO_APPLICANT_SDK_TOKEN_KEY_PREFIX => 'ONFIDO::SDK::TOKEN::';

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

subtest 'onfido websocket api using redis events' => sub {
    onfido_websocket_api_test(BOM::Config::Redis::redis_events_write(), 'test1_2', 'emailtest1_2@email.com');
};

sub onfido_websocket_api_test {
    my ($redis, $applicant_id, $email, $mock) = @_;

    my $counter     = 0;
    my $onfido_mock = Test::MockModule->new('WebService::Async::Onfido');
    my $token_mock  = Test::MockModule->new('BOM::Config');
    my $dog_mock    = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @metrics;
    $dog_mock->mock(
        'stats_inc',
        sub {
            push @metrics, @_;
            push @metrics, 1 if scalar @metrics % 2 != 0;

            return 1;
        });
    $token_mock->mock(
        'third_party',
        sub {
            return {onfido => {authorization_token => 'dummy'}};
        });

    $onfido_mock->mock(
        'sdk_token',
        sub {
            $counter += 1;
            return Future->done({token => 'doge'});
        });
    $onfido_mock->mock(
        'applicant_create',
        sub {
            return Future->done(
                bless {
                    id => $applicant_id,
                },
                'WebService::Async::Onfido::Applicant'
            );
        });

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('asdf12345'),
        email_verified => 1,
    );
    $user->add_client($client);
    $client->binary_user_id($user->id);
    $client->user($user);
    $client->save;
    $client->place_of_birth('br');
    $client->residence('br');
    $client->save;

    my $args = {
        service  => 'onfido',
        referrer => 'https://www.binary.com/'
    };
    my $m     = BOM::Platform::Token::API->new;
    my $token = $m->create_token($client->loginid, 'test token 123');

    my $c   = Test::BOM::RPC::QueueClient->new();
    my $res = $c->tcall(
        'service_token',
        {
            token => $token,
            args  => $args
        });

    cmp_deeply + {@metrics},
        +{
        'bom_rpc.v_3.call.count' => {tags => ['rpc:service_token', 'stream:general']},
        'onfido.api.hit'         => 1,
        },
        'Expected dd metrics';

    $res = $c->tcall(
        'service_token',
        {
            token => $token,
            args  => $args
        });
    $res = $c->tcall(
        'service_token',
        {
            token => $token,
            args  => $args
        });
    $res = $c->tcall(
        'service_token',
        {
            token => $token,
            args  => $args
        });

    is $counter, 1, 'The counter should be 1';

    # need to shut down the mock
    if ($mock) {
        $mock->unmock('get');
    }

    ## check if redis indeed has the cached token (doge)
    is $redis->get(ONFIDO_APPLICANT_SDK_TOKEN_KEY_PREFIX . $client->binary_user_id), 'doge', 'Token set correctly';
    # check if the redis key indeed has a ttl
    ok $redis->ttl(ONFIDO_APPLICANT_SDK_TOKEN_KEY_PREFIX . $client->binary_user_id) > 0, 'TTL set';
}

done_testing();
