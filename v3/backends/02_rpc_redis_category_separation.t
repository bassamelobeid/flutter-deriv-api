#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Scalar::Util qw( looks_like_number );
use JSON::MaybeUTF8 qw(decode_json_utf8);
use Mojo::IOLoop;
use Syntax::Keyword::Try;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper qw(build_wsapi_test call_instrospection test_schema);
use BOM::Config::Redis;

use BOM::Test::Script::RpcRedis;

use await;

my $redis;
my $api;

BEGIN {
    $redis = BOM::Config::Redis::redis_rpc_write();
    $api   = build_wsapi_test();
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

$mock_cg_backend->mock('timeout', BOOT_TIMEOUT);

my $mock_http_backend = Test::MockModule->new('Mojo::WebSocketProxy::Backend::JSONRPC');
$mock_http_backend->mock(
    'call_rpc',
    sub {
        my (undef, undef, $req_storage) = @_;
        push @http_requests, $req_storage;
        return $mock_http_backend->original('call_rpc')->(@_);
    });

my $email    = 'abcd@bincary.com';
my $password = 'jskjd8292922';

my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client_cr->set_default_account('USD');
$client_cr->email($email);
$client_cr->save;
my $cr_1 = $client_cr->loginid;

my $user = BOM::User->create(
    email    => $email,
    password => $password
);

$user->add_client($client_cr);

subtest 'Dynamic category timeouts' => sub {
    # run general consumer
    my $rpc_redis = BOM::Test::Script::RpcRedis->new('general');

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $cr_1);
    my $request = {authorize => $token};
    ok my $response = send_request($request, 'authorize');
    ok !$response->{error}, 'There is no error in response';
    ok $response = pop @queue_requests, 'Request was handled via consumer groups backend';
    is_deeply $response->{args}, $request, "Request and Response's args are equal";

    my $params = {
        account_type    => 'gaming',
        country         => 'mt',
        email           => 'test.account@binary.com',
        name            => 'Meta traderman',
        mainPassword    => 'Efgh4567',
        leverage        => 100,
        dry_run         => 1,
        mt5_new_account => 1,
    };

    # mt5 rpc calls should not work with other consumer worker groups e.g general, payments, etc.
    ok $response = send_request($params, 'mt5_new_account');
    my $timeout = 0;
    Mojo::IOLoop->timer(BOOT_TIMEOUT + 1 => sub { ++$timeout });
    Mojo::IOLoop->one_tick while !($timeout or scalar($api->{messages}->@*));
    ok $timeout, 'Timed out correctly';

    my $pid = $rpc_redis->pid;
    ok looks_like_number($pid), "Valid consumer worker process id: $pid";
    $rpc_redis->stop_script();
    ok !kill(0, $pid), 'Consumer worker process killed successfully';

    flush_redis();

    # mt5 rpc calls work with mt5 specific consumer
    $rpc_redis = BOM::Test::Script::RpcRedis->new('mt5');

    ok $response = send_request($params, 'mt5_new_account');
    ok !$response->{error}, 'There is no error in response';
    ok $response = pop @queue_requests, 'Request was handled via consumer groups backend';
    is_deeply $response->{args}, $params, "Request and Response's args are equal";

    $pid = $rpc_redis->pid;
    ok looks_like_number($pid), "Valid consumer worker process id: $pid";
    $rpc_redis->stop_script();
    ok !kill(0, $pid), 'Consumer worker process killed successfully';

    flush_redis();
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

sub flush_redis {
    $redis->execute("FLUSHDB");

    return undef;
}
done_testing();

1;
