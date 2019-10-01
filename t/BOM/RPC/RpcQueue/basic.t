#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;

use BOM::Test::Helper qw(build_wsapi_test call_instrospection);
use BOM::Test::RPC::Client;
use BOM::Test::RPC::Client::Queue;
use BOM::Test::Script::RpcQueue;
use BOM::Test::WebsocketAPI::Redis;

my $c_queue = BOM::Test::RPC::Client::Queue->new();
my $c_http = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

subtest 'Method call over rpc queue' => sub {
    my $request = {
        'reset_password'    => 1,
        'verification_code' => 'dummy_dummy',
        'new_password'      => 'dummy_dummy',
    };
    ok my $result1 = $c_queue->call_ok('reset_password', {args => $request})->has_no_system_error->result;
    ok my $result2 = $c_http->call_ok('reset_password', {args => $request})->has_no_system_error->result;

    is_deeply $result1, $result2, 'The same result from queue and http rpc for reset password';

    ok $result1 = $c_queue->call_ok('residence_list')->has_no_system_error->result;
    ok $result2 = $c_http->call_ok('residence_list')->has_no_system_error->result;

    is_deeply $result1, $result2, 'The same result from queue and http rpc for residence_list';

    is $c_http->_tcall('no_existing_method'), undef, 'No result for invalid method call';
    $c_queue->call_ok('no_existing_method')->has_no_system_error->has_error->error_code_is('UnknownMethod');
};

subtest 'Redis failure recovery' => sub {
    my $redis = BOM::Test::WebsocketAPI::Redis::redis_queue();
    ok $redis->then(sub { shift->client_kill('SKIPME', 'no') })->get, 'Redis server closed all existing connections';
    $c_queue->client->start->get;
    ok my $result = $c_queue->call_ok('residence_list')->has_no_system_error, 'Queue client and worker recovered from connection loss';
    ok $result->has_no_error, 'RPC response has no error';
};

subtest 'Worker service restart' => sub {
    my $rpc_queue = BOM::Test::Script::RpcQueue::get_script;
    my $pid       = $rpc_queue->pid;
    $rpc_queue->stop_script();
    ok !`ps -p $pid | grep $pid`, 'Worker process is killed successfully';

    my $mocked_script = Test::MockModule->new('BOM::Test::Script');
    $mocked_script->mock(
        args => sub { my $script = shift; return $mocked_script->original('args')->($script) . ' --redis redis://127.0.0.1:15004' },
    );
    $rpc_queue->start_script;
    $pid = $rpc_queue->pid;
    $rpc_queue->stop_script();
    ok !`ps -p $pid | grep $pid`, 'Worker process is killed successfully while disconnected from redis';

    $mocked_script->unmock_all;
    $rpc_queue->start_script;
};

done_testing();
