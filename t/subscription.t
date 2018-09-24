use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Fatal;
use Test::Exception;
use Test::MockModule;
use Test::Refcount;
use Scalar::Util qw(weaken refaddr);
use Binary::WebSocketAPI::v3::Subscription;
use Binary::WebSocketAPI::v3::Subscription::Transaction;
use Binary::WebSocketAPI::v3::SubscriptionManager;
use JSON::MaybeUTF8 qw(:v1);

{

    package Example1;
    use Moo;
    use Test::More;
    with 'Binary::WebSocketAPI::v3::SubscriptionRole';
    our @MESSAGES;
    our @ERRORS;
    sub channel        { 'example1' }
    sub handle_message { my $self = shift; push @MESSAGES, [Scalar::Util::refaddr($self), @_] }
    sub handle_error   { my $self = shift; push @ERRORS, [Scalar::Util::refaddr($self), @_] }

    sub subscription_manager {
        return Binary::WebSocketAPI::v3::SubscriptionManager->shared_redis_manager();
    }
}

{

    package Example2;
    use Moo;
    use Test::More;
    with 'Binary::WebSocketAPI::v3::SubscriptionRole';
    our @MESSAGES;
    our @ERRORS;
    sub channel        { 'example2' }
    sub handle_message { my $self = shift; push @MESSAGES, [Scalar::Util::refaddr($self), @_] }
    sub handle_error   { my $self = shift; push @ERRORS, [Scalar::Util::refaddr($self), @_] }

    sub subscription_manager {
        return Binary::WebSocketAPI::v3::SubscriptionManager->shared_redis_manager();
    }
}

my $redis = Test::MockModule->new('Mojo::Redis2');
my (@subscription_requests, @unsubscription_requests);
$redis->mock(
    subscribe => sub {
        shift;    # discard the instance, we only want the parameters
        push @subscription_requests, [@_];
    });
$redis->mock(
    unsubscribe => sub {
        shift;    # discard the instance, we only want the parameters
        push @unsubscription_requests, [@_];

    });
my %callbacks;
$redis->mock(
    on => sub {
        my $self = shift;
        while (my ($type, $code) = splice @_, 0, 2) {
            $callbacks{$type} = $code;
        }
    });

subtest 'SubscriptionRole class general test' => sub {
    my $c      = {};
    my $worker = new_ok(
        Example1 => [
            c    => $c,
            args => {},
            uuid => '1234'
        ]);
    my $subscription_callback_called;
    is_oneref($worker->c, 'c has refcount 1');
    is($worker->subscription, undef, 'subscription still not defined');
    $worker->subscribe(sub { $subscription_callback_called = shift->channel });
    weaken(my $subscription = $worker->subscription);
    weaken(my $status       = $subscription->status);
    is_oneref($worker, 'worker has refcount 1');
    is(@subscription_requests, 1, 'have a single Redis subscription request');
    isa_ok($status, 'Future');
    ok(!$status->is_ready, 'subscription starts out unstatus');
    isa_ok($subscription, 'Binary::WebSocketAPI::v3::Subscription');
    is_oneref($subscription, 'subscription has one ref');
    isa_ok($subscription->worker, 'Example1', 'has a worker');
    ok(!$subscription_callback_called, "subscription callback not called yet");
    {
        my $req = shift @subscription_requests or die 'no subscription request queued';
        cmp_deeply($req->[0], [$worker->channel], 'channel parameter was correct');
        is(
            exception {
                $req->[1]->();
            },
            undef,
            'can run callback with no exceptions'
        );
        ok($worker->status->is_done, 'subscription is now done') or die 'subscription invalid';
        is($subscription_callback_called, $worker->channel, 'the subscription callback is called, and can visit worker');
    }
    is_oneref($worker, 'worker still has refcount 1');
    isa_ok(my $on_message = $callbacks{message}, 'CODE') or die 'no on_message callback';
    is(@Example1::MESSAGES, 0, 'start with no messages');
    is(@Example1::ERRORS,   0, 'no errors either');
    is(
        exception {
            $on_message->(undef, encode_json_utf8({data => 'here'}) => $worker->channel);
        },
        undef,
        'can trigger message with no failures'
    );
    is(@Example1::MESSAGES, 1, 'now have one message received');
    is(@Example1::ERRORS,   0, 'no errors yet');
    is(
        exception {
            $on_message->(undef, encode_json_utf8({error => {code => 'Testing'}}) => $worker->channel);
        },
        undef,
        'can trigger message with no failures'
    );
    is(@Example1::MESSAGES, 1, 'still have one message received');
    is(@Example1::ERRORS,   1, 'but now also have an error');
    undef $worker;
    ok(!$subscription, 'subscription destroyed');
    ok($status,        'but status future is still there, because there is a ref in the redis unsubscribe callback');
    is(@unsubscription_requests, 1, 'There is an unsubscribe request');
    my $unsubscribe = shift @unsubscription_requests;
    is($unsubscribe->[0][0], 'example1', 'unsubscribe example1');
    $unsubscribe->[1]->();
    undef $unsubscribe;
    ok(!$status, 'Now status is destroyed');
    done_testing;
};

subtest "multi subscription to one channel" => sub {
    @Example1::MESSAGES = ();
    my $example11 = new_ok(
        Example1 => [
            c    => {},
            args => {},
            uuid => '1234'
        ]);
    my $example12 = new_ok(
        Example1 => [
            c    => {},
            args => {},
            uuid => '1234'
        ]);

    my $example13 = new_ok(
        Example1 => [
            c    => {},
            args => {},
            uuid => '1234'
        ]);

    my @subscribe_callback_called;

    $example11->subscribe(sub { push @subscribe_callback_called, 'example11' });
    $example12->subscribe(sub { push @subscribe_callback_called, 'example12' });
    is(@subscription_requests,     1,                  'there is only one requests because we need only subscribe once from redis');
    is($example11->status,         $example12->status, 'they have same "status" future object');
    is(@subscribe_callback_called, 0,                  'no any subscribe cb called');
    {
        my $req = shift @subscription_requests;
        $req->[1]->();
        is_deeply(\@subscribe_callback_called, [qw(example11 example12)], '2 subscribe cb called');
        @subscribe_callback_called = ();
    }
    isa_ok(my $on_message = $callbacks{message}, 'CODE') or die 'no on_message callback';
    is(@Example1::MESSAGES, 0, 'start with no messages');
    $on_message->(undef, encode_json_utf8({data => 'msg1'}) => $example11->channel);
    my @addrs = (sort { $a <=> $b } (refaddr($example11), refaddr($example12)));
    is_deeply([sort { $a->[0] <=> $b->[0] } @Example1::MESSAGES], [map { [$_, {data => 'msg1'}] } @addrs], '2 worker received message');
    @Example1::MESSAGES = ();
    $example13->subscribe(sub { push @subscribe_callback_called, 'example13' });
    is_deeply(\@subscribe_callback_called, [qw(example13)], 'example 13 called at once subscribe cb called');
    is(@subscription_requests, 0, 'new subscription will not make real new subscription to redis');
    lives_ok { $on_message->(undef, encode_json_utf8({data => 'msg2'}) => $example11->channel); } 'message can be processed';
    @addrs = (sort { $a <=> $b } (@addrs, refaddr($example13)));

    @Example1::MESSAGES = ();
    lives_ok { $example13->subscribe() } 'Maybe one worker will subscribe many times by mistake, but dont worry';
    lives_ok { $on_message->(undef, encode_json_utf8({data => 'msg3'}) => $example11->channel); } 'message can still be processed';
    is_deeply([sort { $a->[0] <=> $b->[0] } @Example1::MESSAGES], [map { [$_, {data => 'msg3'}] } @addrs], '3 worker received message');

    my $example21 = new_ok(
        Example2 => [
            c    => {},
            args => {},
            uuid => '1234'
        ]);
    $example21->subscribe();
    is(@subscription_requests, 1, 'new subscription for different channel');
    my $status = $example21->status;
    undef $example21;
    is(@unsubscription_requests, 1, 'There is an unsubscribe request');
    my $req = shift @unsubscription_requests;
    is($req->[0][0], 'example2', 'unsubscribe example2');
    lives_ok { $req->[1]->(); } 'run unsubscribe callback';
    ok($status->is_cancelled, 'future cancelled');

    # test race conditions
    undef $example13;
    undef $example12;
    is(@unsubscription_requests, 0, 'There is no unsubscribe request to redis because that channel still has client');
    @Example1::MESSAGES = ();
    lives_ok { $on_message->(undef, encode_json_utf8({data => 'msg4'}) => $example11->channel); } 'message can still be processed';
    is_deeply(\@Example1::MESSAGES, [[refaddr($example11), {data => 'msg4'}]], 'only one worker received message now');
    undef $example11;
    is(@unsubscription_requests, 1, 'This is the last client. so redis will receive the unsubscribe request');
    $req = shift @unsubscription_requests;
    is($req->[0][0], 'example1', 'unsubscribe example1');
    @Example1::MESSAGES = ();
    lives_ok { $on_message->(undef, encode_json_utf8({data => 'msg5'}) => 'example1'); } 'message can still be processed';
    is(@Example1::MESSAGES, 0, 'no message sent out because no receiver');
    my $example14 = new_ok(
        Example1 => [
            c    => {},
            args => {},
            uuid => '1234'
        ]);
    $example14->subscribe();
    lives_ok { $on_message->(undef, encode_json_utf8({data => 'msg6'}) => 'example1'); } 'message can still be processed';
    is_deeply(\@Example1::MESSAGES, [[refaddr($example14), {data => 'msg6'}]], 'only one worker received message now');
    lives_ok { $req->[1]->() } 'unsubscribed callback executed';
    @Example1::MESSAGES = ();
    lives_ok { $on_message->(undef, encode_json_utf8({data => 'msg7'}) => 'example1'); } 'message can still be processed';
    is_deeply(\@Example1::MESSAGES, [[refaddr($example14), {data => 'msg7'}]], 'latest worker still can receive message now');
    done_testing;
};

done_testing;

