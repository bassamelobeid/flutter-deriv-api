#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Scalar::Util qw( looks_like_number );
use JSON::MaybeUTF8 qw(decode_json_utf8);
use Mojo::IOLoop;

use BOM::Config::RedisReplicated;

use BOM::Test::Helper qw(build_wsapi_test call_instrospection);
use BOM::Test::Script::RpcQueue;
use BOM::Test::WebsocketAPI::Redis;

my @queue_requests;
my @http_requests;

use constant BOOT_TIMEOUT => 5;

my $mock_queue_backend = Test::MockModule->new('Mojo::WebSocketProxy::Backend::JobAsync');
$mock_queue_backend->mock(
    'call_rpc',
    sub {
        my (undef, undef, $req_storage) = @_;
        push @queue_requests, $req_storage;
        return $mock_queue_backend->original('call_rpc')->(@_);
    });

my $mock_http_backend = Test::MockModule->new('Mojo::WebSocketProxy::Backend::JSONRPC');
$mock_http_backend->mock(
    'call_rpc',
    sub {
        my (undef, undef, $req_storage) = @_;
        push @http_requests, $req_storage;
        return $mock_http_backend->original('call_rpc')->(@_);
    });

my $t            = build_wsapi_test();
my $redis        = BOM::Test::WebsocketAPI::Redis::redis_queue();
my $queue_prefix = $ENV{JOB_QUEUE_PREFIX};

subtest 'queue worker service unavailability' => sub {
    my $req = {states_list => 'be'};
    # switch to rpc queue backend
    my $rpc_queue       = BOM::Test::Script::RpcQueue::get_script;
    my $expected_result = {
        states_list => 'queue_backend',
        id          => 1
    };
    is_deeply call_instrospection('backend', ['states_list', 'queue_backend']), $expected_result, 'Backend switched successfully';

    $req = {states_list => 'in'};
    ok my $res = await_with_timeout($t, $req, 'states_list'), 'Response is recieved after switching to rpc queue';
    ok !$res->{error}, 'There is no error in response';
    ok $res = pop @queue_requests, 'Request was caught by queue backend';
    is_deeply $res->{args}, $req, 'Request content was correct';
    ok !@http_requests, 'No request caught by http backend';

    my $pid = $rpc_queue->pid;
    ok looks_like_number($pid), "Valid worker process id: $pid";
    $rpc_queue->stop_script();
    ok !kill(0, $pid), 'Worker process killed successfully';
    ok $res = await_with_timeout($t, $req, 'states_list'), 'A message is recieved after stopping the queue worker';
    ok $res->{error}, 'There is error in response due to timeout.';
    is $res->{error}->{code}, 'RequestTimeout', 'The expected error code is recieved.';

    is my @jobs = $redis->then(sub { shift->keys('job*') })->get->@*, 1, 'One job is remaining in the queue';
    is my @pending = $redis->then(sub { shift->lrange("${queue_prefix}::pending", 0, -1) })->get->@*, 1, 'There is one pending job';

    is 'job::' . $pending[0], $jobs[0], 'Pending job id is matching';

    $rpc_queue->start_script();
    ok looks_like_number($pid = $rpc_queue->pid), "Valid worker process id: $pid";

    my $timeout = 0;
    my $id = Mojo::IOLoop->timer(BOOT_TIMEOUT + $ENV{QUEUE_TIMEOUT} => sub { ++$timeout });
    Mojo::IOLoop->one_tick while !($timeout or scalar($t->{messages}->@*));

    ok $timeout, 'No message is recieved for the expired request after rpc workers are restarted';

    is my @hanging_jobs = $redis->then(sub { shift->keys('job*') })->get->@*, 1, 'There is a job left in the queue';
    is $hanging_jobs[0], $jobs[0], 'Hanging job is the job that was timed-out';
    $redis->then(sub { shift->del($jobs[0]) })->get;
    is $redis->then(sub { shift->keys("*pending") })->get->@*,    0, 'Pending list is empty';
    is $redis->then(sub { shift->keys("*processing") })->get->@*, 0, 'Processing list is empty';

    $expected_result = {
        states_list => 'default',
        id          => 1
    };
    is_deeply call_instrospection('backend', ['states_list', 'default']), $expected_result, 'Backend swithed back to default';
};

subtest 'redis connnection loss' => sub {
    my $req = {states_list => 'be'};
    # switch to rpc queue backend
    my $rpc_queue       = BOM::Test::Script::RpcQueue::get_script;
    my $expected_result = {
        states_list => 'queue_backend',
        id          => 1
    };
    is_deeply call_instrospection('backend', ['states_list', 'queue_backend']), $expected_result, 'Backend switched successfully';

    #receive message from rpc queue
    $req = {states_list => 'in'};
    ok my $res = await_with_timeout($t, $req, 'states_list'), 'Message is recieved after switching to rpc queue';
    ok !$res->{error}, 'There is no error in response';
    ok $res = pop @queue_requests, 'Request was caught by queue backend';
    is_deeply $res->{args}, $req, 'Request content was correct';
    ok !@http_requests, 'No request caught by http backend';

    # disconnecting from redis
    $redis->then(sub { shift->client_kill('SKIPME', 'no') })->get;
    ok $res = await_with_timeout($t, $req, 'states_list'), 'Message is recieved after resetting redis connection';
    ok $res->{error}, 'There is an error immediately afterwards';

    for my $i (0 .. BOOT_TIMEOUT) {
        last unless $res->{error};
        sleep(1);
        note "Waiting for worker and client restart: $i";
        $res = await_with_timeout($t, $req, 'states_list');
    }
    ok !$res->{error}, 'A healthy message is finally received';

    is $redis->then(sub { shift->keys("*pending") })->get->@*,    0, 'Pending list is empty';
    is $redis->then(sub { shift->keys("*processing") })->get->@*, 0, 'Processing list is empty';

    $expected_result = {
        states_list => 'default',
        id          => 1
    };
    is_deeply call_instrospection('backend', ['states_list', 'default']), $expected_result, 'Backend switched back to default';
    for my $job ($redis->then(sub { shift->keys("job*") })->get->@*) {
        $redis->then(sub { shift->del($job) })->get;
    }
    is $redis->then(sub { shift->keys("job*") })->get->@*, 0, 'No job left in the queue';
};

sub await_with_timeout {
    my ($t, $request, $expected_msg_type) = @_;
    my $result = 0;

    $t->send_ok({json => $request});

    my $timeout = 0;
    my $id = Mojo::IOLoop->timer($ENV{QUEUE_TIMEOUT} + 1 => sub { ++$timeout });
    Mojo::IOLoop->one_tick while !($timeout or scalar($t->{messages}->@*));

    if ($expected_msg_type) {
        ok scalar $t->{messages}->@*, 'Response received';
        my $msg = decode_json_utf8((shift $t->{messages}->@*)->[1]);
        is $msg->{msg_type}, $expected_msg_type, "Correct message type";
        $result = $msg if ($msg->{msg_type} eq $expected_msg_type);
    } else {
        ok $result = $timeout, 'Timeout is reached';
    }

    return $result;
}

sub fail_with_timeout {
    my ($t, $request) = @_;
    return await_with_timeout($t, $request);
}

done_testing();

1;
