use strict;
use warnings;
use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::MockObject;
use Test::Warn;
use Log::Any::Test;
use BOM::Event::QueueHandler;
use Log::Any qw($log);
use Log::Any::Adapter (qw(Stderr), log_level => 'warn');
use JSON::MaybeUTF8 qw(decode_json_utf8 decode_json_text);
use IO::Async::Loop;
use Future::AsyncAwait;
use utf8;

my $loop = IO::Async::Loop->new;
my $stream_handler;
my $mock_log_adapter_test = Test::MockModule->new('Log::Any::Adapter::Test');
my $mocked_handler        = Test::MockModule->new('BOM::Event::QueueHandler');
my $mocked_process        = Test::MockModule->new('BOM::Event::Process');
my $redis_object          = Test::MockObject->new;

$mock_log_adapter_test->mock(
    'is_debug',
    sub {
        return 0;
    });

subtest 'items to reprocess' => sub {

    # Getting "oldest" (by idle time) item to be processed first

    my $next = 0;

    my $pendings       = [['123-0', '', 50000, 1], ['123-1', '', 60001, 1]];
    my $claims         = [['123-0', ['event', '{"type":"new_event"}']], ['123-1', ['event', '{"type":"very_old_event"}']]];
    my $expected_event = [{
            event       => '{"type":"very_old_event"}',
            id          => '123-1',
            retry_count => 2,
            stream      => 'TEST_STREAM'
        }];

    $redis_object->mock('connected', async sub { Future->done });
    $redis_object->mock('xpending',  async sub { $next++; return $pendings });
    $redis_object->mock('xclaim',    async sub { return [@$claims[$next]]; });
    $redis_object->mock('xack',      async sub { Future->done });

    $mocked_handler->mock('redis', sub { $redis_object });

    $loop->add($stream_handler = BOM::Event::QueueHandler->new(streams => ['TEST_STREAM']));

    my $returned_event = $stream_handler->items_to_reprocess()->get;

    is_deeply $returned_event, $expected_event, 'Expected event returned for reprocess';

    $mocked_handler->unmock_all();
    $log->clear;

    # Item not ready to be retried

    $pendings = [['123-0', '', 50000, 1]];
    $claims   = [['123-0', ['event', '{"type":"event_to_retry"}']]];
    my @acked = ();

    $redis_object = Test::MockObject->new;
    $redis_object->mock('connected', async sub { Future->done });
    $redis_object->mock('xpending',  async sub { return [@$pendings[0]] });
    $redis_object->mock('xclaim',    async sub { Future->done });
    $redis_object->mock('xack',      async sub { push @acked, @$pendings[0]; return @acked; });

    $mocked_handler->mock('redis', sub { $redis_object });

    $loop->add($stream_handler = BOM::Event::QueueHandler->new(streams => ['TEST_STREAM']));

    $returned_event = $stream_handler->items_to_reprocess()->get;

    is $returned_event, undef, 'The event is not ready to be retried';
    is scalar @acked,   0,     'Item correctly marked as not being acknowledged';

    $mocked_handler->unmock_all();
    $log->clear;

    # Exceeding number of retries

    $pendings = [['123-0', '', 60001, 6]];
    $claims   = [['123-0', ['event', '{"type":"event_to_retry"}']]];
    @acked    = ();

    $redis_object = Test::MockObject->new;
    $redis_object->mock('connected', async sub { Future->done });
    $redis_object->mock('xpending',  async sub { return [@$pendings[0]] });
    $redis_object->mock('xclaim',    async sub { return [@$claims[0]]; });
    $redis_object->mock('xack',      async sub { push @acked, @$pendings[0]; return @acked; });

    $mocked_handler->mock('redis', sub { $redis_object });

    $loop->add($stream_handler = BOM::Event::QueueHandler->new(streams => ['TEST_STREAM']));

    $returned_event = $stream_handler->items_to_reprocess()->get;

    $log->contains_ok(qr/Exceeded number of retries for 'event_to_retry' event from 'TEST_STREAM'/, "The error message is returned correctly");
    is_deeply \@acked, $pendings, 'Expected event acked';

    $mocked_handler->unmock_all();
    $log->clear;

    # Pagination and multiple streams

    my $pendings_pg1 = undef;
    my $pendings_pg2 = [['123-0', '', 60001, 1]];

    $claims = [['123-0', ['event', '{"type":"event_to_retry"}']]];

    $expected_event = [{
            event       => '{"type":"event_to_retry"}',
            id          => '123-0',
            retry_count => 2,
            stream      => 'TEST_STREAM_2'
        }];

    $next         = 0;
    $redis_object = Test::MockObject->new;
    $redis_object->mock('connected', async sub { Future->done });
    $redis_object->mock('xpending',  async sub { $next++; $next == 1 ? return $pendings_pg1 : return [@$pendings_pg2[0]] });
    $redis_object->mock('xclaim',    async sub { return [@$claims[0]]; });
    $redis_object->mock('xack',      async sub { Future->done });

    $mocked_handler->mock('redis', sub { $redis_object });

    $loop->add($stream_handler = BOM::Event::QueueHandler->new(streams => ['TEST_STREAM', 'TEST_STREAM_2']));

    $returned_event = $stream_handler->items_to_reprocess()->get;

    is_deeply $returned_event, $expected_event, 'Expected event returned for reprocess';

    # Claimed items

    $pendings = [['123-0', '', 60001, 1], ['123-1', '', 60001, 1]];
    $claims   = [['123-0', ['event', '{"type":"claimed_event"}']], ['123-1', ['event', '{"type":"unclaimed_event"}']]];

    $expected_event = [{
            event       => '{"type":"unclaimed_event"}',
            id          => '123-1',
            retry_count => 2,
            stream      => 'TEST_STREAM'
        }];

    $next         = 0;
    $redis_object = Test::MockObject->new;
    $redis_object->mock('connected', async sub { Future->done });
    $redis_object->mock('xpending',  async sub { return [@$pendings[$next]] });
    $redis_object->mock('xclaim',    async sub { $next++; return [@$claims[$next]]; });
    $redis_object->mock('xack',      async sub { Future->done });

    $mocked_handler->mock('redis', sub { $redis_object });

    $loop->add($stream_handler = BOM::Event::QueueHandler->new(streams => ['TEST_STREAM']));

    $returned_event = $stream_handler->items_to_reprocess()->get;

    is_deeply $returned_event, $expected_event, 'Expected event returned for reprocess';
};

subtest 'stream process loop' => sub {

    # Retry mechanism off

    $mocked_handler = Test::MockModule->new('BOM::Event::QueueHandler');
    my @created  = ();
    my $pendings = [['123-0', '', 60001, 1]];
    my @acked    = ();
    my $claims   = [['123-0', ['event', '{"type":"event_to_retry"}']]];

    $redis_object = Test::MockObject->new;
    $redis_object->mock('xpending',  async sub { return [@$pendings[0]] });
    $redis_object->mock('xclaim',    async sub { return [@$claims[0]]; });
    $redis_object->mock('connected', async sub { Future->done });
    $redis_object->mock('xinfo',     async sub { return [] });
    $redis_object->mock('xgroup',    async sub { push @created, [$_[2], $_[3]]; });
    $mocked_handler->mock('redis', sub { $redis_object });

    $loop->add($stream_handler = BOM::Event::QueueHandler->new(streams => ['TEST_STREAM']));

    my $items = [{
            event       => '{"type":"event_to_retry"}',
            id          => '123-0',
            retry_count => 1,
            stream      => 'TEST_STREAM'
        }];
    $mocked_handler->redefine('get_stream_items' => async sub { $stream_handler->{request_counter}++; return $items; });
    $mocked_handler->redefine('process_job'      => async sub { die "Failed to process the event" });
    $mocked_handler->redefine('_ack_message'     => async sub { push @acked, @$pendings[0]; $items = [] });
    $stream_handler->{request_counter} = 4999;
    Future->wait_any($stream_handler->stream_process_loop, $loop->delay_future(after => 1))->get;

    $log->contains_ok(qr/Failed to process the event/, "The error message is returned correctly");
    is_deeply \@acked, $pendings, 'Expected event acked';

    $mocked_handler->unmock_all();
    $log->clear;

    # Retry mechanism on

    $mocked_handler = Test::MockModule->new('BOM::Event::QueueHandler');
    my $next = 0;
    @created  = ();
    $pendings = [['123-0', '', 60001, 1]];
    @acked    = ();
    $claims   = [['123-0', ['event', '{"type":"event_to_retry"}']]];

    $redis_object = Test::MockObject->new;
    $redis_object->mock('xpending',  async sub { $next == 0 ? return [@$pendings[$next]] : return undef });
    $redis_object->mock('xclaim',    async sub { return [@$claims[$next]]; });
    $redis_object->mock('connected', async sub { Future->done });
    $redis_object->mock('xinfo',     async sub { return [] });
    $redis_object->mock('xgroup',    async sub { push @created, [$_[2], $_[3]]; });
    $mocked_handler->mock('redis', sub { $redis_object });

    $loop->add($stream_handler = BOM::Event::QueueHandler->new(streams => ['TEST_STREAM']));

    $items = [{
            event       => '{"type":"event_to_retry"}',
            id          => '123-0',
            retry_count => 4,
            stream      => 'TEST_STREAM'
        }];

    $stream_handler->{request_counter} = 4999;

    $mocked_handler->redefine('retry_interval'   => sub { return 1; });
    $mocked_handler->redefine('get_stream_items' => async sub { $stream_handler->{request_counter}++; return $items; });
    $mocked_handler->redefine('process_job'      => async sub { $next++;                              die "Failed to process the event" });
    $mocked_handler->redefine('_ack_message'     => async sub { push @acked, @$pendings[0];           $items = [] });
    Future->wait_any($stream_handler->stream_process_loop, $loop->delay_future(after => 1))->get;

    is scalar @acked, 0, 'Item correctly marked as not being acknowledged';

};

$mock_log_adapter_test->unmock_all;

done_testing();
