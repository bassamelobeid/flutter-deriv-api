use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::Fatal;
use Test::MockObject;
use Test::MockModule;
use Test::MockTime::HiRes qw(mock_time);
use BOM::Transport::RedisAPI;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use RedisDB;

my $response_messages = {
    dummy           => {result => 1234},
    dummy_string    => 'Dummy String',
    with_message_id => {
        message_id => 1234,
    },
    with_wrong_message_id => {
        message_id => 4567,
    },
    with_response                => {response => {result => 1234}},
    with_message_id_and_response => {
        message_id => 1234,
        response   => {result => 1234}
    },
    undef => undef,
};

my $requests = {
    simple => {
        message_id => 1234,
        rpc        => 'dummy_rpc'
    },
    another_simple => {
        message_id => 4567,
        rpc        => 'dummy_rpc'
    },
    timedout => {
        message_id => 1234,
        rpc        => 'dummy_rpc',
        deadline   => time - 10
    },
};
my $errors = {
    timeout => {
        code    => BOM::Transport::RedisAPI::ERROR_CODES->{TIMEOUT},
        message => ignore()
    },
    unknown => {
        code    => BOM::Transport::RedisAPI::ERROR_CODES->{UNKNOWN},
        message => ignore()
    },
    redisdb => {
        code    => BOM::Transport::RedisAPI::ERROR_CODES->{REDISDB},
        type    => ignore(),
        message => ignore()
    },
};

my @dummy_config = (
    redis_config => {
        host => 'dummy',
        port => 1234,
    });

subtest 'new instance throws error when missing params' => sub {
    dies_ok {
        BOM::Transport::RedisAPI->new
    }
    'Should die if no redis nor redis_config is provided';
};

subtest 'process message' => sub {
    # mock redis db
    my $mock_redisdb = Test::MockModule->new('RedisDB');
    $mock_redisdb->mock('new' => sub { return Test::MockObject->new; });

    my $redis_api = BOM::Transport::RedisAPI->new(@dummy_config);

    is_deeply(
        $redis_api->process_message($requests->{simple}, encode_json_utf8($response_messages->{with_message_id_and_response})),
        $response_messages->{with_message_id_and_response},
        'message with expected properties successfully parsed'
    );
    is $redis_api->process_message($requests->{another_simple}, encode_json_utf8($response_messages->{with_message_id_and_response})), undef,
        'message not for the same request ignored';
    is $redis_api->process_message($requests->{simple}, encode_json_utf8($response_messages->{with_message_id})), undef,
        'message without response returns undef';
    is $redis_api->process_message($requests->{simple}, encode_json_utf8($response_messages->{with_response})), undef,
        'message without message_id returns undef';
    is $redis_api->process_message($requests->{simple}, $response_messages->{dummy_string}), undef, 'non json messages returns undef';

};

subtest 'send request' => sub {
    # mock redis
    my $mock_redis = Test::MockObject->new;
    my @commands   = ();
    $mock_redis->mock('execute' => sub { push @commands, $_[1]; });
    my $redis_api = BOM::Transport::RedisAPI->new(redis => $mock_redis);

    $redis_api->send_request($requests->{simple});
    is $commands[0], 'MULTI',     'should call MULTI in transaction mode';
    is $commands[1], 'XADD',      'should call XADD in transaction mode';
    is $commands[2], 'subscribe', 'should call subscribe in transaction mode';
    is $commands[3], 'EXEC',      'should call EXEC in transaction mode';
};

subtest 'wait for reply' => sub {

    # mock redis
    my $mock_redis  = Test::MockObject->new;
    my $reply_ready = 0;
    $mock_redis->mock('reply_ready' => sub { return $reply_ready; });

    subtest 'requests passed the deadline will result in timeout' => sub {
        my $redis_api = BOM::Transport::RedisAPI->new(redis => $mock_redis);
        cmp_deeply exception {
            $redis_api->wait_for_reply($requests->{timedout});
        }, $errors->{timeout}, 'should die if deadline is passed';
    };

    subtest 'requests with no deadline will timeout if default timeout reached' => sub {
        # mock redis api
        my $mock_redis_api = Test::MockModule->new('BOM::Transport::RedisAPI');
        $mock_redis_api->mock('default_end_time' => sub { return time - 10; });

        my $redis_api = BOM::Transport::RedisAPI->new(
            redis       => $mock_redis,
            wait_period => 1
        );
        mock_time {
            cmp_deeply exception {
                $redis_api->wait_for_reply($requests->{simple});
            }, $errors->{timeout}, 'should die if default timeout passed';
        }
        time;
    };

    subtest 'the wating time is being controlled by wait_period and it sleeps' => sub {
        # mock redis api
        my $mock_redis_api = Test::MockModule->new('BOM::Transport::RedisAPI');
        $mock_redis_api->mock('default_end_time' => sub { return time + 0.1; });    #allow it it enter the loop.

        # mock Time::HiRes::usleep
        my $mock_hres    = Test::MockModule->new("Time::HiRes");
        my @sleep_params = ();
        $mock_hres->mock('usleep' => sub { @sleep_params = @_; return $mock_hres->original('usleep')->(@_); });

        my $redis_api = BOM::Transport::RedisAPI->new(
            redis       => $mock_redis,
            wait_period => 1e6
        );
        mock_time {
            dies_ok { $redis_api->wait_for_reply($requests->{simple}) } 'timeout ok';
            is $sleep_params[0], 1e6, 'should call usleep with wait_period';
        }
        time;
    };

    subtest 'ignore not related messages and returns only the response of the sent request' => sub {
        my $reply;
        $mock_redis->mock('get_reply' => sub { return $reply; });

        # mock redis api
        my $mock_redis_api = Test::MockModule->new('BOM::Transport::RedisAPI');
        $mock_redis_api->mock('default_end_time' => sub { return time + 0.1; });    #allow it it enter the loop.
        $mock_redis_api->mock('process_message'  => sub { return $_[2]; });
        my $redis_api = BOM::Transport::RedisAPI->new(
            redis       => $mock_redis,
            wait_period => 1e6
        );

        $reply_ready = 1;
        $reply       = ['subscribe', 'abcd', 1];
        mock_time {
            cmp_deeply exception {
                $redis_api->wait_for_reply($requests->{simple});
            }, $errors->{timeout}, 'should die if not message';
        }
        time;

        $reply = ['message', 'dummy', encode_json_utf8($response_messages->{with_message_id})];
        mock_time {
            is_deeply $redis_api->wait_for_reply($requests->{simple}), encode_json_utf8($response_messages->{with_message_id}),
                'should return response if message processed';
        }
        time;
    };
};

subtest 'call rpc' => sub {
    # mock redis
    my $mock_redis = Test::MockObject->new;

    # mock redis api
    my $mock_redis_api = Test::MockModule->new('BOM::Transport::RedisAPI');
    my $redis_api      = BOM::Transport::RedisAPI->new(redis => $mock_redis);
    $mock_redis_api->mock('wait_for_reply' => sub { $response_messages->{with_message_id}; });
    subtest 'all required redis commands are called and response is returned' => sub {
        my $methods_called;
        $mock_redis_api->mock(
            'send_request' => sub { $methods_called += 1; },
            'subscribe'    => sub { $methods_called += 10; },
            'unsubscribe'  => sub { $methods_called += 100; },
        );
        is $redis_api->call_rpc($requests->{simple}), $response_messages->{with_message_id}, 'should return response if response is received';
        is $methods_called,                           111,                                   'should call send_request, subscribe and unsubscribe';
    };

    subtest 'unsubscribe will be called even if the request failed' => sub {
        my $methods_called = 0;
        $mock_redis_api->mock(
            'send_request' => sub { die 'error'; },
            'subscribe'    => sub { $methods_called += 10; },
            'unsubscribe'  => sub { $methods_called += 100; },
        );
        dies_ok { $redis_api->call_rpc($requests->{simple}); } 'should die if call_rpc dies';
        is $methods_called, 100, 'should still call unsubscribe if call_rpc dies';
    };

    subtest 'the failure of calling unsubscribe will not cause errors and gracefully handled' => sub {
        my $methods_called = 0;
        $mock_redis_api->mock(
            'send_request' => sub { $methods_called += 1 },
            'subscribe'    => sub { $methods_called += 10; },
            'unsubscribe'  => sub { die 'error' },
        );
        lives_ok { is $redis_api->call_rpc($requests->{simple}), $response_messages->{with_message_id}, 'got response'; }
        'return response even if unsubscribe failed';
    };
};

subtest 'throwing exceptions' => sub {
    # mock redis
    my $mock_redis = Test::MockObject->new;
    my $redis_api  = BOM::Transport::RedisAPI->new(redis => $mock_redis);

    cmp_deeply exception {
        $redis_api->throw_exception('A string error', $requests->{simple});
    }, $errors->{unknown}, 'should throw unknown exception if error is string';

    cmp_deeply exception {
        $redis_api->throw_exception(['array', 'ref'], $requests->{simple});
    }, $errors->{unknown}, 'should throw unknown exception if error is array ref';

    cmp_deeply exception {
        $redis_api->throw_exception({code => 'another_code'}, $requests->{simple});
    }, $errors->{unknown}, 'should trow if error has code but not expected';

    cmp_deeply exception {
        $redis_api->throw_exception($errors->{timeout}, $requests->{simple});
    }, $errors->{timeout}, 'Expected exceptions are thrown';

    my $mock_redisdb_error = Test::MockObject->new;
    $mock_redisdb_error->set_isa('RedisDB::Error');
    cmp_deeply exception {
        $redis_api->throw_exception($mock_redisdb_error, $requests->{simple});
    }, $errors->{redisdb}, 'should throw redisdb exception with error code and message';

};

done_testing();
