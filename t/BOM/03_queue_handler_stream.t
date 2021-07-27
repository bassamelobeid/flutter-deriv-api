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
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_events_redis);
use BOM::Config::Redis;
use IO::Async::Loop;
use Future::AsyncAwait;
use utf8;
initialize_events_redis();
my $redis = BOM::Config::Redis::redis_events_write();
my $loop  = IO::Async::Loop->new;
my $stream_handler;
my $mock_log_adapter_test = Test::MockModule->new('Log::Any::Adapter::Test');
# Need to mock because in `Log::Any::Adapter::Test` is_debug always returns 1 that is used in BOM::Event::QueueHandler->clean_data_for_logging.
$mock_log_adapter_test->mock(
    'is_debug',
    sub {
        return 0;
    });

subtest 'Startup and shutdown stream' => async sub {
    lives_ok { $stream_handler = BOM::Event::QueueHandler->new(stream => 'GENERIC_EVENTS_STREAM') } 'Create new stream instance';
    $loop->add($stream_handler);
    await $stream_handler->should_shutdown;
    throws_ok { $stream_handler->stream_process_loop->get } qr/normal_shutdown/, 'Can shut down';
};

subtest 'Consumer naming' => sub {
    $loop->add(
        $stream_handler = BOM::Event::QueueHandler->new(
            stream       => 'GENERIC_EVENTS_STREAM',
            worker_index => 'WORKER'
        ));
    my $consumername = join '-', $stream_handler->host_name, "WORKER";
    is $stream_handler->consumer_name, "$consumername", 'Correct consumer name assigning';
};

subtest 'Create the stream consumer group' => sub {
    my $redis_object    = Test::MockObject->new;
    my @expected_groups = (['GENERIC_EVENTS_CONSUMERS']);
    my @created         = ();
    $redis_object->mock('connected', async sub { Future->done });
    $redis_object->mock('xinfo',     async sub { return [] });
    $redis_object->mock('xgroup',    async sub { push @created, [$_[3]]; return @created; });
    my $mocked = Test::MockModule->new('BOM::Event::QueueHandler');
    $mocked->mock('redis', sub { $redis_object });
    $loop->add($stream_handler = BOM::Event::QueueHandler->new(stream => 'GENERIC_EVENTS_STREAM'));
    $stream_handler->init_stream->get;
    is_deeply \@created, \@expected_groups, 'Created group';
};

subtest 'Invalid stream messages' => sub {
    $redis->execute("XADD", 'GENERIC_EVENTS_STREAM', '*', 0, 0);
    my $mocked = Test::MockModule->new('BOM::Event::QueueHandler');
    $loop->add($stream_handler = BOM::Event::QueueHandler->new(stream => 'GENERIC_EVENTS_STREAM'));
    my %msg = (
        'event_id' => '0-0',
        'event'    => 'junk'
    );
    $mocked->redefine('get_stream_item' => async sub { return \%msg; });
    Future->wait_any($stream_handler->stream_process_loop, $loop->delay_future(after => 1))->get;
    $log->contains_ok(qr/Bad data received from stream causing exception/, "Expected invalid json warning is thrown");
};

subtest 'Resolve pending messages' => sub {
    my $redis_object = Test::MockObject->new;
    my $pendings     = [['123-0'], ['123-1'], ['123-2'], ['123-3']];
    my @acked        = ();
    $redis_object->mock('connected', async sub { Future->done });
    $redis_object->mock('xpending',  async sub { return [@$pendings] });
    $redis_object->mock('xack',      async sub { push @acked, [$_[3]]; return @acked; });
    my $mocked = Test::MockModule->new('BOM::Event::QueueHandler');
    $mocked->mock('redis', sub { $redis_object });
    $loop->add($stream_handler = BOM::Event::QueueHandler->new(stream => 'GENERIC_EVENTS_STREAM'));
    $stream_handler->_resolve_pending_messages->get;
    is_deeply \@acked, $pendings, 'Pending message marked as acknowledge successfully';
};

subtest 'undefined functions' => sub {
    # undefined functions
    $stream_handler = BOM::Event::QueueHandler->new(stream => 'GENERIC_EVENTS_STREAM');
    $loop->add($stream_handler);
    $stream_handler->process_job('GENERIC_EVENTS_STREAM', {type => 'unknown_function'})->get;
    $log->contains_ok(qr/no function mapping found for event/, "Undefined functions should return an error");
};

subtest 'stream sync_subs' => sub {
    my $module = Test::MockModule->new('BOM::Event::Process');
    $log->clear;
    $module->mock(
        'get_action_mappings',
        sub {
            return {
                sync_sub => sub { sleep(shift->{wait}); $log->warn('test did not time out'); }

            };
        });

    # Synchronous jobs running less  than MAXIMUM_PROCESSING_TIME should not time out
    $log->clear;
    $stream_handler = BOM::Event::QueueHandler->new(
        stream                  => 'GENERIC_EVENTS_STREAM',
        maximum_job_time        => 20,
        maximum_processing_time => 3
    );
    $loop->add($stream_handler);
    $stream_handler->process_job(
        'GENERIC_EVENTS_STREAM',
        {
            type    => 'sync_sub',
            details => {wait => 1}})->get;
    $log->contains_ok(qr/test did not time out/, "Sync job less than max_processing_time did not time out.");

    # Synchronous jobs running more  than MAXIMUM_PROCESSING_TIME should time out
    $log->clear;
    $stream_handler = BOM::Event::QueueHandler->new(
        stream                  => 'GENERIC_EVENTS_STREAM',
        maximum_job_time        => 20,
        maximum_processing_time => 2
    );
    $loop->add($stream_handler);
    $stream_handler->process_job(
        'GENERIC_EVENTS_STREAM',
        {
            type    => 'sync_sub',
            details => {wait => 5}})->get;
    $log->contains_ok(qr/Max_Processing_Time Reached/, "Sync job longer than max_processing_time did time out");

    # We do/can have synchronous tasks declared as async functions this changes the timeout behavior.
    # As they get handled by the L<FUTURE> failure.
    $log->clear;
    $module = Test::MockModule->new('BOM::Event::Process');
    $module->mock(
        'get_action_mappings',
        sub {
            return {
                sync_sub_2 => async sub { sleep(shift->{wait}); $log->warn('test did not time out'); }
            };
        });

    # Synchronous jobs marked as C<async>  should time out  if longer than MAXIMUM_PROCESSING_TIME but they are treated as a L<FUTURE> fail.
    $log->clear;
    $stream_handler = BOM::Event::QueueHandler->new(
        stream                  => 'GENERIC_EVENTS_STREAM',
        maximum_job_time        => 20,
        maximum_processing_time => 1
    );
    $loop->add($stream_handler);
    $stream_handler->process_job(
        'GENERIC_EVENTS_STREAM',
        {
            type    => 'sync_sub_2',
            details => {wait => 2}})->get;
    $log->contains_ok(
        qr/GENERIC_EVENTS_STREAM took longer than 'MAXIMUM_PROCESSING_TIME'/,
        "Sync job marked as async should time out after maximum_processing_time"
    );

    # Synchronous jobs marked as C<async>  should not time out  if shorter  than MAXIMUM_PROCESSING_TIME.
    $log->clear;
    $stream_handler = BOM::Event::QueueHandler->new(
        stream                  => 'GENERIC_EVENTS_STREAM',
        maximum_job_time        => 20,
        maximum_processing_time => 2
    );
    $loop->add($stream_handler);
    $stream_handler->process_job(
        'GENERIC_EVENTS_STREAM',
        {
            type    => 'sync_sub_2',
            details => {wait => 1}})->get;
    $log->contains_ok(qr/test did not time out/, "Sync job marked as async should not time out if less than maximum_processing_time");

    # Synchronous jobs marked as C<async>  should ignore maximum_job_time
    $log->clear;
    $stream_handler = BOM::Event::QueueHandler->new(
        stream                  => 'GENERIC_EVENTS_STREAM',
        maximum_job_time        => 1,
        maximum_processing_time => 5
    );
    $loop->add($stream_handler);
    $stream_handler->process_job(
        'GENERIC_EVENTS_STREAM',
        {
            type    => 'sync_sub_2',
            details => {wait => 3}})->get;
    $log->contains_ok(qr/test did not time out/,
        "Sync job marked as async should not time out if less than maximum_processing_time but greater than maximum_job_time");

    $module->unmock_all();
};

subtest 'async_subs' => sub {

    my $module = Test::MockModule->new('BOM::Event::Process');
    $module->mock(
        'get_action_mappings',
        sub {
            return {
                async_sub_1 => async sub {
                    await $loop->delay_future(after => shift->{wait});
                    return "test did not time out";
                }
            };
        });

    # Test when the Job is Async and shorter then maximum_job_time. Should work OK
    $log->clear;
    $stream_handler = BOM::Event::QueueHandler->new(
        stream                  => 'GENERIC_EVENTS_STREAM',
        maximum_job_time        => 2,
        maximum_processing_time => 10
    );
    $loop->add($stream_handler);
    my $f = $stream_handler->process_job(
        'GENERIC_EVENTS_STREAM',
        {
            type    => 'async_sub_1',
            details => {wait => 1}})->get;

    # Future->wait_any($f, $loop->delay_future(after => 10))->get;
    is $f, 'test did not time out', "Async job less than MAXIMUM_JOB_TIME should not timeout";

    # Test when the job is async but runs too long, should fail the maximum_job_time check.
    $log->clear;
    $f = $stream_handler->process_job(
        'GENERIC_EVENTS_STREAM',
        {
            type    => 'async_sub_1',
            details => {wait => 4}})->get;
    $log->contains_ok(qr/did not complete within 2 sec/, "Async job greater than MAXIMUM_JOB_TIME should timeout");

    # Test when the job is async  and runs longer than MAXIMUM_PROCESSING_TIME, should not fail.
    $log->clear;
    $stream_handler = BOM::Event::QueueHandler->new(
        stream                  => 'GENERIC_EVENTS_STREAM',
        maximum_job_time        => 4,
        maximum_processing_time => 1
    );
    $loop->add($stream_handler);
    $f = $stream_handler->process_job(
        'GENERIC_EVENTS_STREAM',
        {
            type    => 'async_sub_1',
            details => {wait => 2}})->get;
    is $f, 'test did not time out', "Async job greater then MAXIMUM_PROCESSING_TIME but less than MAXIMUM_JOB_TIME should not time out.";
    $module->unmock_all();
};

subtest 'clean_data_for_logging' => sub {
    my $event_data_json       = '{"details":{"loginid":"CR10000","properties":{"type":"real"},"email":"abc@def.com"}}';
    my $expected_cleaned_data = '{"sanitised_details":{"loginid":"CR10000"}}';

    my $cleaned_data = BOM::Event::QueueHandler->clean_data_for_logging($event_data_json);
    is $cleaned_data, $expected_cleaned_data, 'cleaned data is correct for given json data';

    my $event_data_hashref = decode_json_text($event_data_json);
    $cleaned_data = BOM::Event::QueueHandler->clean_data_for_logging($event_data_hashref);
    is $cleaned_data, $expected_cleaned_data, 'cleaned data is correct for given already decode data from json';

    $event_data_json    = '{"details":{"loginid":"CR10000","properties":{"type":"real"},"email":"abc@def.com"},"type":"api_token_deleted"}';
    $event_data_hashref = decode_json_text($event_data_json);
    $cleaned_data       = BOM::Event::QueueHandler->clean_data_for_logging($event_data_hashref);
    is $event_data_hashref->{details}{loginid}, 'CR10000', 'Original Hashref was unmodiflied';

};

subtest 'clean_data_for_logging_utf8' => sub {
    my $event_data_json = Encode::encode("UTF-8",
        '{"details":{"loginid":"CR10000","properties":{"type":"real"},"email":"abc@def.com"},"utf_8":"À Á Â Ã Ä Å Æ Ç È É Ê Ë Ì Í Î Ï Ð Ñ Ò Ó "}');
    my $expected_cleaned_data = '{"sanitised_details":{"loginid":"CR10000"},"utf_8":"À Á Â Ã Ä Å Æ Ç È É Ê Ë Ì Í Î Ï Ð Ñ Ò Ó "}';
    my $cleaned_data          = BOM::Event::QueueHandler->clean_data_for_logging($event_data_json);
    like $cleaned_data, qr/"utf_8":"À Á Â Ã Ä Å Æ Ç È É Ê Ë Ì Í Î Ï Ð Ñ Ò Ó "/, 'utf_8 characters OK when JSON string with UTF8 passed';

    my $event_data_hashref = decode_json_utf8($event_data_json);
    $cleaned_data = BOM::Event::QueueHandler->clean_data_for_logging($event_data_hashref);
    like $cleaned_data, qr/"utf_8":"À Á Â Ã Ä Å Æ Ç È É Ê Ë Ì Í Î Ï Ð Ñ Ò Ó "/, 'utf_8 character OK when UTF8 in hashref';

};
$mock_log_adapter_test->unmock_all;

done_testing();
