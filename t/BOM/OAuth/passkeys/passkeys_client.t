use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Mojo;
use Test::MockModule;
use Test::MockObject;

use BOM::OAuth::Passkeys::PasskeysClient;

subtest 'redis_api' => sub {
    subtest 'redis_api returns redis_api object' => sub {
        my $mock_redis_api = Test::MockModule->new('BOM::Transport::RedisAPI');
        my $call_count     = 0;
        $mock_redis_api->mock(
            'new' => sub {
                $call_count++;
                return 'redis_api object';
            });
        my $passkeys_client = BOM::OAuth::Passkeys::PasskeysClient->new;
        is($passkeys_client->redis_api, 'redis_api object', 'redis_api object exists');

        $passkeys_client->redis_api;
        is($call_count, 1, 'redis_api object is cached');
    };
};

subtest 'passkeys_options' => sub {
    # Mock the redis_api object and its methods
    my $redis_api_mock = Test::MockObject->new;
    $redis_api_mock->set_true('build_rpc_request');
    my $mock_client = Test::MockModule->new('BOM::OAuth::Passkeys::PasskeysClient');
    $mock_client->mock(
        'redis_api' => sub {
            return $redis_api_mock;
        });
    my $client = BOM::OAuth::Passkeys::PasskeysClient->new;

    subtest 'passkeys_options returns the correct options when received from rpc' => sub {
        $redis_api_mock->mock(
            'call_rpc',
            sub {
                return {
                    response => {
                        result => {
                            publicKey => 'test_options',
                        },
                    },
                };
            });
        # Test passkeys_options
        my $options = $client->passkeys_options;
        is($options->{publicKey}, 'test_options', 'passkeys_options returns the correct options');
    };

    subtest 'passkeys_options dies when rpc error' => sub {
        # Test passkeys_options with an error
        $redis_api_mock->mock(
            'call_rpc',
            sub {
                return {
                    response => {
                        result => {
                            error => 'test_error',
                        },
                    },
                };
            });
        dies_ok { $client->get_options }, 'passkeys_options dies with the correct error message';
    };
};

subtest 'passkeys_login' => sub {
    # Mock the redis_api object and its methods
    my $redis_api_mock = Test::MockObject->new;
    $redis_api_mock->set_true('build_rpc_request');
    my $mock_client = Test::MockModule->new('BOM::OAuth::Passkeys::PasskeysClient');
    $mock_client->mock(
        'redis_api' => sub {
            return $redis_api_mock;
        });
    my $client = BOM::OAuth::Passkeys::PasskeysClient->new;

    subtest 'passkeys_login returns the user details when received from rpc' => sub {
        my $test_result = {
            binary_user_id => 'test_user_id',
            email          => 'test_email',
            verified       => 1,
        };

        $redis_api_mock->mock(
            'call_rpc',
            sub {
                return {
                    response => {result => $test_result},
                };
            });

        my $verify_result = $client->passkeys_login('test_auth_response');
        is_deeply($verify_result, $test_result, 'passkeys_login returns the correct options');
    };

    subtest 'passkeys_login dies when rpc error' => sub {
        # Test passkeys_login with an error
        $redis_api_mock->mock(
            'call_rpc',
            sub {
                return {
                    response => {
                        result => {
                            error => 'test_error',
                        },
                    },
                };
            });
        dies_ok { $client->passkeys_login('test_auth_response') }, 'passkeys_login dies with the correct error message';
    };
};

done_testing();
