use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;
use Test::MockObject;
use JSON::MaybeUTF8 qw(decode_json_utf8);

use BOM::Platform::Event::Emitter;
use BOM::Platform::Context qw(request);

subtest 'Event emmission' => sub {
    my @datadog_metric;
    my $mock_datadog = Test::MockModule->new('BOM::Platform::Event::Emitter');
    $mock_datadog->redefine(stats_inc => sub { push @datadog_metric, \@_; });

    my @queue_data;
    my $mock_queue = Test::MockObject->new();
    $mock_queue->mock(
        # `execute` is mocked to make the test forward compatible with forthcoming changes towards redis streams
        execute => sub { shift; push @queue_data, \@_; },
        # TODO: this mock should be removed as soon as we switch to redis stream.
        lpush => sub { shift; push @queue_data, \@_ },
    );

    $mock_queue->mock(
        # TODO: this mock should be removed as soon as we switch to redis stream.
        lpush => sub { shift; push @queue_data, \@_ },
    );

    my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
    $mock_emitter->redefine(_write_connection => sub { return $mock_queue });

    my $context = {
        brand_name => 'binary',
        language   => 'id',
        app_id     => 100
    };
    my $req = BOM::Platform::Context::Request->new(%$context);
    request($req);

    my $event = 'dummy_event';
    my $args  = {
        a => 1,
        b => 2
    };
    BOM::Platform::Event::Emitter::emit($event, $args);
    is scalar @queue_data, 1, 'And event is emitted.';

    if (scalar $queue_data[0]->@* == 2) {
        # TODO: this block should be removed as soon as we switch to redis stream.
        # if we are here, it means that we are still using `lpush` for event emission.
        $queue_data[0]->[1] = decode_json_utf8($queue_data[0]->[1]);
        is_deeply $queue_data[0],
            [
            'GENERIC_EVENTS_QUEUE',
            {
                type    => 'dummy_event',
                context => $context,
                details => $args,
            },
            ],
            'Correct event info pushed to redis';

        is scalar @datadog_metric, 1, 'One metric is measured';
        is_deeply $datadog_metric[0], ['event_emitter.sent', {'tags' => ['type:dummy_event', 'queue:GENERIC_EVENTS_QUEUE']}],
            'Mertic args are correct.';
    } else {
        # If we reach here, it means that we've switched to redis stream
        is scalar $queue_data[0]->@*, 8, 'Number of args is correct';

        $queue_data[0]->[7] = decode_json_utf8($queue_data[0]->[7]);
        is_deeply $queue_data[0],
            [
            'XADD',
            'GENERIC_EVENTS_STREAM',
            'MAXLEN', '~', '100000', '*', 'event',
            {
                type    => 'dummy_event',
                context => $context,
                details => $args,
            }
            ],
            'Streamed content is correct.';

        is scalar @datadog_metric, 1, 'One metric is measured';
        is_deeply $datadog_metric[0], ['event_emitter.sent', {'tags' => ['type:dummy_event', 'queue:GENERIC_EVENTS_QUEUE']}],
            'Mertic args are correct.';
    }

    $mock_emitter->unmock_all;
    $mock_datadog->unmock_all;
};

done_testing;

1;
