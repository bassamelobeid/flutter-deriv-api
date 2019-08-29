#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;
use JSON::MaybeUTF8 qw(decode_json_utf8);
use Mojo::IOLoop;
use Test::MockModule;

use BOM::Test::Helper qw(build_wsapi_test call_instrospection);
use BOM::Test::Script::RpcQueue;

my @queue_requests;
my @http_requests;

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

my $t = build_wsapi_test();

subtest 'validation' => sub {
    is call_instrospection('backend', [])->{error}, 'No method name is specified (usage: backend <method> <backend>)',
        'Corect method-name error message';
    is call_instrospection('backend', ['dummy'])->{error}, "Method 'dummy' was not found", 'Correct error message for invalid method';
    is call_instrospection('backend', ['exchange_rates'])->{error}, 'No backend name is specified (usage: backend <method> <backend>)',
        'Correct backend-name error message';
    is call_instrospection('backend', ['exchange_rates', 'dummy'])->{error},
        "Backend 'dummy' was not found. Available backends: default (or http), queue_backend",
        'Correct error message for invalid backend';
    is call_instrospection('backend', ['exchange_rates', 'default'])->{error},
        "Backend is already set to 'default' for method 'exchange_rates'. Nothing is changed.", 'Error if setting the same backend';
};

subtest 'swtich ws backend' => sub {
    my $req = {states_list => 'be'};
    ok await_with_timeout($t, $req, 'states_list'), 'Message is recieved before switching to rpc queue';
    ok my $res = pop @http_requests, 'Request was caught by http backend';
    is_deeply $res->{args}, $req, 'Request content was correct';
    ok !@queue_requests, 'No request caught by queue backend';

    # switch to rpc queue backend
    my $rpc_queue       = BOM::Test::Script::RpcQueue::get_script;
    my $expected_result = {
        states_list => 'queue_backend',
        id          => 1
    };
    is_deeply call_instrospection('backend', ['states_list', 'queue_backend']), $expected_result, 'Backend swithed successfully';

    #receive message from rpc queue
    $req = {states_list => 'in'};
    ok await_with_timeout($t, $req, 'states_list'), 'Message is recieved after switching to rpc queue';
    ok $res = pop @queue_requests, 'Request was caught by queue backend';
    is_deeply $res->{args}, $req, 'Request content was correct';
    ok !@http_requests, 'No request caught by http backend';

    # stop rpc queue
    $req = {states_list => 'us'};
    $rpc_queue->stop_script();
    ok await_with_timeout($t, $req), 'No message is recieved when rpc queue is stopped';
    ok $res = pop @queue_requests, 'Request was caught by queue backend';
    is_deeply $res->{args}, $req, 'Request content was correct';
    ok !@http_requests, 'No request caught by http backend';

    # restart rpc queue
    $rpc_queue->start_script_if_not_running();
    $t   = $t->message_ok;
    $res = decode_json_utf8($t->message->[1]);
    is $res->{msg_type}, 'states_list', 'The missing message is recieved after rpc queue is started';
};

subtest 'control options' => sub {
    is_deeply call_instrospection('backend', ['--list']),
        {
        id           => 1,
        backend_list => 'default (or http), queue_backend'
        },
        'List of backends is correct';
};

sub await_with_timeout {
    my ($t, $request, $expected_msg_type) = @_;
    my $result = 0;

    $t->send_ok({json => $request});

    my $timeout = 0;
    my $id = Mojo::IOLoop->timer(2 => sub { ++$timeout });
    Mojo::IOLoop->one_tick while !($timeout or scalar($t->{messages}->@*));

    if ($expected_msg_type) {
        ok $t->{messages}, 'Response received';
        my $msg = decode_json_utf8((shift $t->{messages}->@*)->[1]);
        is $msg->{msg_type}, $expected_msg_type, "Correct message type";
        $result = $msg if ($msg->{msg_type} eq $expected_msg_type);
    } else {
        ok $result = $timeout, 'Timeout is reached';
    }

    return $result;
}

done_testing();

1;
