use strict;
use warnings;

use Syntax::Keyword::Try;

use Test::More;
use Test::Deep;
use Test::MockModule;
use Test::MockObject;
use JSON::MaybeUTF8 qw(decode_json_utf8);

use BOM::Platform::Event::Notifier;
use BOM::Platform::Event::RedisConnection;

subtest 'Notification event' => sub {
    my @datadog_metric;
    my $mock_datadog = Test::MockModule->new('BOM::Platform::Event::Notifier');
    $mock_datadog->redefine(stats_inc => sub { push @datadog_metric, \@_; });

    my @queue_data;
    my $mock_queue = Test::MockObject->new();
    $mock_queue->mock(
        execute => sub { shift; push @queue_data, \@_; },
    );

    my $mock_redis = Test::MockModule->new('BOM::Platform::Event::Notifier');
    $mock_redis->redefine(_write_connection => sub { return $mock_queue });

    my $event_add = {
        binary_user_id => 'user123',
        message_id     => 'financial-assessment-notification',
        payload        => {"key" => "value"},
        source_id      => 'abc123',
        category       => 'act',
    };

    BOM::Platform::Event::Notifier::notify_add($event_add);
    is scalar @queue_data, 1, 'An event is added.';

    is_deeply $queue_data[0],
        [
        'XADD',       'NOTIFICATIONS::EVENTS', 'MAXLEN', '~', '100000', '*', 'operation', 'add', 'binary_user_id', 'user123', 'category', 'act',
        'message_id', 'financial-assessment-notification',
        'source_id',  'abc123', 'payload', '{"key":"value"}',
        ],
        'Streamed content is correct for add.';

    is scalar @datadog_metric, 1, 'One metric is measured for add';
    is_deeply $datadog_metric[0],
        ['notify_emitter.sent', {'tags' => ['operation:add', 'message_id:financial-assessment-notification', 'queue:NOTIFICATIONS::EVENTS']}],
        'Metric args are correct for add.';

    my $event_delete = {
        binary_user_id => 'user123',
        message_id     => 'financial-assessment-notification',
        source_id      => 'abc123',
    };

    @queue_data     = ();
    @datadog_metric = ();
    BOM::Platform::Event::Notifier::notify_delete($event_delete);
    is scalar @queue_data, 1, 'An event is deleted.';

    is_deeply $queue_data[0],
        [
        'XADD',       'NOTIFICATIONS::EVENTS', 'MAXLEN', '~', '100000', '*', 'operation', 'delete', 'binary_user_id', 'user123', 'category', undef,
        'message_id', 'financial-assessment-notification',
        'source_id',  'abc123', 'payload', '',
        ],
        'Streamed content is correct for delete.';

    is scalar @datadog_metric, 1, 'One metric is measured for delete';
    is_deeply $datadog_metric[0],
        ['notify_emitter.sent', {'tags' => ['operation:delete', 'message_id:financial-assessment-notification', 'queue:NOTIFICATIONS::EVENTS']}],
        'Metric args are correct for delete.';

    @queue_data = ();
    my $event_add_missing_param = {
        message_id => 'financial-assessment-notification',
        payload    => {"key" => "value"},
        source_id  => 'abc123',
        category   => 'act',
    };

    try {
        BOM::Platform::Event::Notifier::notify_add($event_add_missing_param);
    } catch ($e) {
        like $e, qr/Missing required parameter: binary_user_id/, 'should die when binary_user_id not present';
    }
    is scalar @queue_data, 0, 'An event is not added when a required parameter is missing.';

    # Additional test cases for other invalid parameters
    my $event_invalid_operation = {
        binary_user_id => 'user123',
        message_id     => 'financial-assessment-notification',
        payload        => {"key" => "value"},
        source_id      => 'abc123',
        category       => 'act',
        operation      => 'update',
    };

    try {
        BOM::Platform::Event::Notifier::_notify($event_invalid_operation);
    } catch ($e) {
        like $e, qr/Invalid value for parameter: operation/, 'should die when operation is invalid';
    }
    is scalar @queue_data, 0, 'An event is not added when operation is invalid.';

    my $event_payload_too_long = {
        binary_user_id => 'user123',
        message_id     => 'financial-assessment-notification',
        payload        => {"key" => 'a' x 2049},
        source_id      => 'abc123',
        category       => 'act',
    };

    try {
        BOM::Platform::Event::Notifier::notify_add($event_payload_too_long);
    } catch ($e) {
        like $e, qr/length of payload exceeded MAX_PAYLOAD_SIZE: 2048/, 'should die when payload is too long';
    }
    is scalar @queue_data, 0, 'An event is not added when payload is too long.';

    my $event_source_id_too_long = {
        binary_user_id => 'user123',
        message_id     => 'financial-assessment-notification',
        payload        => {"key" => "value"},
        source_id      => 'a' x 51,
        category       => 'act',
    };

    try {
        BOM::Platform::Event::Notifier::notify_add($event_source_id_too_long);
    } catch ($e) {
        like $e, qr/length of source_id exceeded MAX_SOURCE_ID_SIZE: 50/, 'should die when source_id is too long';
    }
    is scalar @queue_data, 0, 'An event is not added when source_id is too long.';

    my $event_invalid_json_payload = {
        binary_user_id => 'user123',
        message_id     => 'financial-assessment-notification',
        payload        => 'a string',
        source_id      => 'abc123',
        category       => 'act',
    };

    try {
        BOM::Platform::Event::Notifier::notify_add($event_invalid_json_payload);
    } catch ($e) {
        like $e, qr/Invalid JSON payload/, 'should die when payload is invalid JSON';
    }
    is scalar @queue_data, 0, 'An event is not added when payload is invalid JSON.';

    $mock_redis->unmock_all;
    $mock_datadog->unmock_all;
};

done_testing;

1;
