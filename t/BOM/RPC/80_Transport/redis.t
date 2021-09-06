use strict;
use warnings;

use JSON::MaybeUTF8 qw/ decode_json_utf8 /;
use Test::MockObject;
use Log::Any::Test;
use Log::Any qw($log);
use Test::More;
use Test::Exception;
use Test::MockModule;
use RedisDB::Error;

use BOM::RPC::Transport::Redis;

my $mock_log_adapter = Test::MockModule->new('Log::Any::Adapter::Test');
$mock_log_adapter->mock('is_debug', 0);

subtest 'Create object' => sub {
    lives_ok {
        create_transport_redis_instance();
    }
    "Object created successfully";

    throws_ok sub {
        create_transport_redis_instance(worker_index => undef);
    }, qr/worker_index|required/, "Couldn't create object without worker_index";

    throws_ok sub {
        create_transport_redis_instance(
            redis     => undef,
            redis_uri => undef,
        );
    }, qr/redis|defined/, "Couldn't create object without redis_uri and redis";
};

subtest 'Error Ignoring' => sub {
    my $redis = Test::MockObject->new();

    my $err_msg = {redis => RedisDB::Error->new('BUSYGROUP Consumer Group name already exists')};

    $redis->mock(
        execute => sub {
            die $err_msg;
        });

    my $instance = create_transport_redis_instance(redis => $redis);

    lives_ok { $instance->initialize_connection() } "Error: '$err_msg' is ignored";
};

subtest 'Consumer naming' => sub {
    my $instance = create_transport_redis_instance(
        host         => my $host = 'host02',
        worker_index => my $w_i  = 0,
        pid          => my $pid  = 123,
        category     => my $cat  = 'mt5'
    );

    is $instance->consumer_name,   "$host-$w_i",      'Correct consumer name assigning';
    is $instance->connection_name, "$cat-$host-$pid", 'Correct connection name';
};

subtest 'Resolve pending messages' => sub {
    my $redis = Test::MockObject->new();

    my $pendings = [['123-0'], ['123-1'], ['123-2'], ['123-3']];

    my @acked = ();

    $redis->mock(
        execute => sub {
            my ($self, @cmd) = @_;

            if ($cmd[0] eq 'XPENDING') {
                return $pendings;
            } elsif ($cmd[0] eq 'XACK') {
                push @acked, [$cmd[3]];
            }
        });

    my $instance = create_transport_redis_instance(redis => $redis);
    $instance->_resolve_pending_messages();

    is_deeply \@acked, $pendings, 'Pending message marked as acknowledge successfully';
};

subtest 'Parse message' => sub {
    # What redis given us
    my $raw_msg =
        [['mt5', [['123123123-0', ['who', 'd11221d', 'rpc', 'ping', 'args', '{"key":"val"}', 'deadline', '999', 'stash', '{"key":"value"}']]]]];

    my $expected = {
        message_id => '123123123-0',
        payload    => {
            who      => 'd11221d',
            rpc      => 'ping',
            args     => {key => "val"},
            deadline => '999',
            stash    => {key => "value"}}};

    my $instance = create_transport_redis_instance();

    my $parsed = $instance->_parse_message($raw_msg);

    is_deeply $expected, $parsed, 'Raw message parsed to hash';

    $raw_msg = [['mt5', [['123123123-0', ['who', 'd11221d', 'args', '{"key":"val"}', 'deadline', '999', 'stash', '{"key":"value"}']]]]];

    dies_ok { $instance->_parse_message($raw_msg) } 'Missing rpc parameter reported';

    $raw_msg = [['mt5', [['123123123-0', ['rpc', 'ping', 'args', '{"key":"val"}', 'deadline', '999', 'stash', '{"key":"value"}']]]]];

    dies_ok { $instance->_parse_message($raw_msg) } 'Missing who parameter reported';

    $raw_msg = [['mt5', [['123123123-0', ['who', 'd11221d', 'rpc', 'ping']]]]];

    lives_ok { $instance->_parse_message($raw_msg) } 'Message parsed successfully without unnecessary params';

    $raw_msg = [['mt5', [['123123123-0', ['who', 'd11221d', 'rpc', 'ping', 'args', '{"loginid":"GDPR900001"{']]]]];
    dies_ok { $instance->_parse_message($raw_msg) } 'Died due to wrong json format';
    $log->contains_ok(qr/HIDDEN/, "Sensitive data are hidden");

};

subtest 'Response' => sub {
    my $redis = Test::MockObject->new();

    my $published;
    $redis->mock(
        execute => sub {
            my ($self, @args) = @_;
            if ($args[0] eq 'PUBLISH') {
                $published = {
                    channel_id => $args[1],
                    message    => $args[2]};
            }
        });

    my $instance = create_transport_redis_instance(redis => $redis);

    $instance->_publish_response('dummy-ch', '{"test": 1}');

    is $published->{channel_id}, 'dummy-ch', 'Response is published to correct channel';
    is_deeply decode_json_utf8($published->{message}), {test => 1}, 'Response is correct';
};

sub create_transport_redis_instance {
    return BOM::RPC::Transport::Redis->new(
        redis        => 'dummy',
        host         => 'host01',
        cateogry     => 'mt5',
        pid          => 123,
        worker_index => 0,
        @_
    );
}

done_testing();
