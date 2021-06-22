#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Scalar::Util qw( looks_like_number );
use JSON::MaybeUTF8 qw(decode_json_utf8);
use Mojo::IOLoop;

use BOM::Test::Helper qw(build_wsapi_test call_instrospection);
use BOM::Config::Redis;

use BOM::Test::Script::RpcRedis;

my $redis;
my $api;

BEGIN {
    $ENV{TEST_REDIRECT_RPC_QUEUES} = 0;

    $api   = build_wsapi_test();
    $redis = BOM::Config::Redis::redis_rpc_write();
}

use constant BOOT_TIMEOUT => 5;

my @queue_requests;
my @http_requests;

my $mock_cg_backend = Test::MockModule->new('Mojo::WebSocketProxy::Backend::ConsumerGroups');
$mock_cg_backend->mock(
    'call_rpc',
    sub {
        my (undef, undef, $req_storage) = @_;
        push @queue_requests, $req_storage;
        return $mock_cg_backend->original('call_rpc')->(@_);
    });

$mock_cg_backend->mock('_rpc_category_timeout', BOOT_TIMEOUT);

my $mock_http_backend = Test::MockModule->new('Mojo::WebSocketProxy::Backend::JSONRPC');
$mock_http_backend->mock(
    'call_rpc',
    sub {
        my (undef, undef, $req_storage) = @_;
        push @http_requests, $req_storage;
        return $mock_http_backend->original('call_rpc')->(@_);
    });
subtest 'Consumer service unavailability' => sub {
    # switch to rpc backend
    my $rpc_redis = BOM::Test::Script::RpcRedis->new();

    my $request = {states_list => 'be'};
    ok my $response = send_request($request, 'states_list'), 'Response is recieved after switching to consumer groups';
    ok !$response->{error}, 'There is no error in response';
    ok $response = pop @queue_requests, 'Request was handled via consumer groups backend';
    is_deeply $response->{args}, $request, "Request and Response's args are equal";
    ok !@http_requests, 'No request is handled by http backend';

    my $pid = $rpc_redis->pid;
    ok looks_like_number($pid), "Valid consumer worker process id: $pid";
    $rpc_redis->stop_script();
    ok !kill(0, $pid), 'Consumer worker process killed successfully';

    $redis->flushdb();

    ok $response = send_request($request, 'states_list'), 'Response received after stopping Consumer';
    ok $response->{error}, 'Response contains error paramater';
    is $response->{error}->{code}, 'WrongResponse', 'Response error is WrongResponse because of timeout and as our expectation';

    my $stream_len = $redis->execute("XLEN", "general");
    is $stream_len, 1, 'Request streamed by Producer even without Consumer presence';

    $rpc_redis->start_script();
    ok looks_like_number($pid = $rpc_redis->pid), "Valid consumer worker process id: $pid";

    my $timeout = 0;
    Mojo::IOLoop->timer(BOOT_TIMEOUT + 1 => sub { ++$timeout });
    Mojo::IOLoop->one_tick while !($timeout or scalar($api->{messages}->@*));
    ok $timeout, 'No message is recieved for the expired request after rpc workers are restarted';

    $rpc_redis->stop_script();
    ok !kill(0, $pid), 'Consumer worker process killed successfully';

    ok send_request($request, 'states_list', 0), 'Send another request while Consumer is stopped';

    $rpc_redis->start_script();
    ok looks_like_number($pid = $rpc_redis->pid), "Valid consumer worker process id: $pid";

    $timeout = 0;
    Mojo::IOLoop->timer(BOOT_TIMEOUT + 1 => sub { ++$timeout });
    Mojo::IOLoop->one_tick while !($timeout or scalar($api->{messages}->@*));
    ok scalar($api->{messages}->@*), 'Message is received for not expired request immedietly after running Cosnumer';

    is_deeply call_instrospection('backend', ['states_list', 'http'])->{error}, "Backend 'http' was not found. Available backends: rpc_redis",
        'Backend swithed back to http';

    $rpc_redis->stop_script();
    ok !kill(0, $pid), 'Consumer worker process killed successfully';

    $redis->flushdb();
};

subtest 'redis connnection loss' => sub {
    # switch to rpc redis backend
    my $rpc_redis = BOM::Test::Script::RpcRedis->new();

    my $request = {states_list => 'be'};
    ok my $response = send_request($request, 'states_list'), 'Response is recieved after switching to consumer groups';
    ok !$response->{error}, 'There is no error in response';
    ok $response = pop @queue_requests, 'Request was handled via consumer groups backend';
    is_deeply $response->{args}, $request, "Request and Response's args are equal";
    ok !@http_requests, 'No request is handled by http backend';

    my $client_name_before = $redis->execute("CLIENT", "GETNAME");

    # disconnecting from Redis
    $redis->execute("CLIENT", "KILL", 'SKIPME', 'no');
    ok $response = send_request($request, 'states_list', 0), 'Response is recieved after killing redis client';
    my $timeout = 0;
    Mojo::IOLoop->timer(BOOT_TIMEOUT + 1 => sub { ++$timeout });
    Mojo::IOLoop->one_tick while !($timeout or scalar($api->{messages}->@*));
    ok scalar($api->{messages}->@*), 'Message is received for not expired request immedietly after running Cosnumer';

    is $redis->execute("CLIENT", "GETNAME"), $client_name_before, 'Consumer claim same client name as before killing';
    $rpc_redis->stop_script();
};

sub send_request {
    my ($request, $expected_msg_type, $wait_for) = @_;

    $wait_for //= BOOT_TIMEOUT + 1;

    $api->send_ok({json => $request});

    return 1 unless $wait_for;

    my $result;

    my $timedout = 0;
    Mojo::IOLoop->timer($wait_for => sub { $timedout = 1 });
    Mojo::IOLoop->one_tick while !($timedout or scalar($api->{messages}->@*));

    ok scalar $api->{messages}->@*, 'Response received';
    my $msg = decode_json_utf8((shift $api->{messages}->@*)->[1]);
    is $msg->{msg_type}, $expected_msg_type, "Correct message type";
    $result = $msg if ($msg->{msg_type} eq $expected_msg_type);

    return $result;
}

done_testing();

1;
