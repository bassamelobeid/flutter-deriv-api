use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::Warn;
use Log::Any::Test;
use BOM::Event::QueueHandler;
use Log::Any qw($log);
use Log::Any::Adapter (qw(Stderr), log_level => 'warn');
use JSON::MaybeUTF8 qw(decode_json_utf8);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_events_redis);
use BOM::Config::Redis;
use IO::Async::Loop;
use Future::AsyncAwait;
initialize_events_redis();
my $redis = BOM::Config::Redis::redis_events_write();
my $loop  = IO::Async::Loop->new;
my $handler;
my $mock_log_adapter_test = Test::MockModule->new('Log::Any::Adapter::Test');
# Need to mock because in `Log::Any::Adapter::Test` is_debug always returns 1 that is used in OM::Event::QueueHandler->clean_data_for_logging.
$mock_log_adapter_test->mock(
    'is_debug',
    sub {
        return 0;
    });

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

subtest 'undefined functions' => sub {
    # undefined functions
    $handler = BOM::Event::QueueHandler->new(queue => 'GENERIC_EVENTS_QUEUE');
    $loop->add($handler);
    $handler->process_job('GENERIC_EVENTS_QUEUE', {type => 'unknown_function'});
    $log->contains_ok(qr/no function mapping found for event/, "undefined functions should return an error");
};

subtest 'sync_subs' => sub {

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
    $handler = BOM::Event::QueueHandler->new(
        queue                   => 'GENERIC_EVENTS_QUEUE',
        maximum_job_time        => 20,
        maximum_processing_time => 3
    );
    $loop->add($handler);
    $handler->process_job(
        'GENERIC_EVENTS_QUEUE',
        {
            type    => 'sync_sub',
            details => {wait => 1}});
    $log->contains_ok(qr/test did not time out/, "Sync job less than max_processing_time did not time out.");

    # Synchronous jobs running more  than MAXIMUM_PROCESSING_TIME should time out
    $log->clear;
    $handler = BOM::Event::QueueHandler->new(
        queue                   => 'GENERIC_EVENTS_QUEUE',
        maximum_job_time        => 20,
        maximum_processing_time => 2
    );
    $loop->add($handler);
    $handler->process_job(
        'GENERIC_EVENTS_QUEUE',
        {
            type    => 'sync_sub',
            details => {wait => 5}});
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
    $handler = BOM::Event::QueueHandler->new(
        queue                   => 'GENERIC_EVENTS_QUEUE',
        maximum_job_time        => 20,
        maximum_processing_time => 1
    );
    $loop->add($handler);
    $handler->process_job(
        'GENERIC_EVENTS_QUEUE',
        {
            type    => 'sync_sub_2',
            details => {wait => 2}});
    $log->contains_ok(
        qr/GENERIC_EVENTS_QUEUE took longer than 'MAXIMUM_PROCESSING_TIME'/,
        "Sync job marked as async should time out after maximum_processing_time"
    );

    # Synchronous jobs marked as C<async>  should not time out  if shorter  than MAXIMUM_PROCESSING_TIME.
    $log->clear;
    $handler = BOM::Event::QueueHandler->new(
        queue                   => 'GENERIC_EVENTS_QUEUE',
        maximum_job_time        => 20,
        maximum_processing_time => 2
    );
    $loop->add($handler);
    $handler->process_job(
        'GENERIC_EVENTS_QUEUE',
        {
            type    => 'sync_sub_2',
            details => {wait => 1}});
    $log->contains_ok(qr/test did not time out/, "Sync job marked as async should not time out if less than maximum_processing_time");

    # Synchronous jobs marked as C<async>  should ignore maximum_job_time
    $log->clear;
    $handler = BOM::Event::QueueHandler->new(
        queue                   => 'GENERIC_EVENTS_QUEUE',
        maximum_job_time        => 1,
        maximum_processing_time => 5
    );
    $loop->add($handler);
    $handler->process_job(
        'GENERIC_EVENTS_QUEUE',
        {
            type    => 'sync_sub_2',
            details => {wait => 3}});
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
                    return await $loop->delay_future(after => shift->{wait})->on_done(sub { $log->warn('test did not time out') });
                }
            };
        });

    # Test when the Job is Async and shorter then maximum_job_time. Should work OK
    $log->clear;
    $handler = BOM::Event::QueueHandler->new(
        queue                   => 'GENERIC_EVENTS_QUEUE',
        maximum_job_time        => 2,
        maximum_processing_time => 10
    );
    $loop->add($handler);
    my $f = $handler->process_job(
        'GENERIC_EVENTS_QUEUE',
        {
            type    => 'async_sub_1',
            details => {wait => 1}});
    $f->get;
    $log->contains_ok(qr/test did not time out/, "Async job less than MAXIMUM_JOB_TIME should not timeout");

    # Test when the job is async but runs too long, should fail the maximum_job_time check.
    $log->clear;
    $f = $handler->process_job(
        'GENERIC_EVENTS_QUEUE',
        {
            type    => 'async_sub_1',
            details => {wait => 4}});
    $f->get;
    $log->contains_ok(qr/did not complete within 2 sec/, "Async job greater than MAXIMUM_JOB_TIME should timeout");

    # Test when the job is async  and runs longer than MAXIMUM_PROCESSING_TIME, should not fail.
    $log->clear;
    $handler = BOM::Event::QueueHandler->new(
        queue                   => 'GENERIC_EVENTS_QUEUE',
        maximum_job_time        => 4,
        maximum_processing_time => 1
    );
    $loop->add($handler);
    $f = $handler->process_job(
        'GENERIC_EVENTS_QUEUE',
        {
            type    => 'async_sub_1',
            details => {wait => 2}});
    $f->get;
    $log->contains_ok(qr/test did not time out/,
        "ASYNC job greater then MAXIMUM_PROCESSING_TIME but less than MAXIMUM_JOB_TIME should not time out.");

    $module->unmock_all();
};

subtest 'clean_data_for_logging' => sub {
    my $event_data_json       = '{"details":{"loginid":"CR10000","properties":{"type":"real"},"email":"abc@def.com"}}';
    my $expected_cleaned_data = '{"sanitised_details":{"loginid":"CR10000"}}';

    my $cleaned_data = BOM::Event::QueueHandler->clean_data_for_logging($event_data_json);
    is $cleaned_data, $expected_cleaned_data, 'cleaned data is correct for given json data';

    my $event_data_hashref = decode_json_utf8($event_data_json);
    $cleaned_data = BOM::Event::QueueHandler->clean_data_for_logging($event_data_hashref);
    is $cleaned_data, $expected_cleaned_data, 'cleaned data is correct for given already decode data from json';
};

$mock_log_adapter_test->unmock_all;

done_testing();
