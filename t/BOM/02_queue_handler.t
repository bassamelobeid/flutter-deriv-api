use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::Warn;

use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_events_redis);
use BOM::Config::RedisReplicated;
use IO::Async::Loop;
use BOM::Event::QueueHandler;

initialize_events_redis();
my $redis = BOM::Config::RedisReplicated::redis_events_write();
my $loop  = IO::Async::Loop->new;
my $handler;

subtest 'startup and shutdown' => sub {
    lives_ok { $handler = BOM::Event::QueueHandler->new(queue => 'GENERIC_EVENTS_QUEUE') } 'create new queue instance';
    $loop->add($handler);
    $handler->should_shutdown->done;
    throws_ok { $handler->process_loop->get } qr/normal_shutdown/, 'can shut down';
};

subtest 'invalid messages' => sub {
    $loop->add($handler = BOM::Event::QueueHandler->new(queue => 'GENERIC_EVENTS_QUEUE'));
    $redis->lpush('GENERIC_EVENTS_QUEUE', 0);
    throws_ok { $handler->process_loop->get } qr/bad event data - nothing received/, 'empty message';

    $redis->lpush('GENERIC_EVENTS_QUEUE', 'junk');
    throws_ok { $handler->process_loop->get } qr/bad event data - malformed JSON string/, 'invalid json';
};

done_testing();
