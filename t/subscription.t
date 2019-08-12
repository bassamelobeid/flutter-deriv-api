use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Fatal;
use Test::Exception;
use Test::MockModule;
use Test::MockObject;
use Test::Refcount;
use Scalar::Util qw(weaken refaddr);
use Log::Any::Test;
use Log::Any qw($log);

use Binary::WebSocketAPI::v3::SubscriptionManager;
use JSON::MaybeUTF8 qw(:v1);

{

    package Example1;
    use Moo;
    use Test::More;
    with 'Binary::WebSocketAPI::v3::Subscription';
    our @MESSAGES;
    our @ERRORS;
    has channel_arg => (is => 'ro');
    sub channel { shift->channel_arg // 'example1' }

    sub handle_message {
        my $self = shift;
        push @MESSAGES, [Scalar::Util::refaddr($self), @_];
    }

    sub handle_error {
        my $self = shift;
        push @ERRORS, [Scalar::Util::refaddr($self), @_];
        return $_[-1];
    }

    sub _unique_key {
        my $self = shift;
        return $self->channel . ($self->args->{subchannel} // '');
    }

    sub subscription_manager {
        return Binary::WebSocketAPI::v3::SubscriptionManager->shared_redis_manager();
    }
}

{

    package Example2;
    use Moo;
    use Test::More;
    with 'Binary::WebSocketAPI::v3::Subscription';
    our @MESSAGES;
    our @ERRORS;
    sub channel { 'example2' }

    sub handle_message {
        my $self = shift;
        push @MESSAGES, [Scalar::Util::refaddr($self), @_];
    }

    sub handle_error {
        my $self = shift;
        push @ERRORS, [Scalar::Util::refaddr($self), @_];
    }

    sub _unique_key {
        my $self = shift;
        return $self->channel . ($self->args->{subchannel} // '');
    }

    sub subscription_manager {
        return Binary::WebSocketAPI::v3::SubscriptionManager->shared_redis_manager();
    }
}

{

    package Binary::WebSocketAPI::v3::Subscription::Example1;
    use Moo;
    extends 'Example1';
}

my $mocked_redis = Test::MockModule->new('Mojo::Redis2');
my (@subscription_requests, @unsubscription_requests);
# executing callbacks in this array means subscribe successfully.
$mocked_redis->mock(
    subscribe => sub {
        shift;    # discard the instance, we only want the parameters
        push @subscription_requests, [@_];
    });
$mocked_redis->mock(
    unsubscribe => sub {
        my $self = shift;
        # call original if it is not unsubscribing channel -- it is unsubscribing EventEmitter events.
        return $mocked_redis->original('unsubscribe')->($self, @_) if ref($_[0]) ne 'ARRAY';
        push @unsubscription_requests, [@_];
    });
my %callbacks;
$mocked_redis->mock(
    on => sub {
        my $self = shift;
        my @args = @_;
        while (my ($type, $code) = splice @_, 0, 2) {
            $callbacks{$type} = $code;
        }
        $mocked_redis->original('on')->($self, @args);
    });

sub mock_c {
    my $c = Test::MockObject->new;
    $c->{stash} = {};
    $c->mock('stash',  sub { return shift->{stash} });
    $c->mock('tx',     sub { return 1 });
    $c->mock('finish', sub { my $self = shift; $self->{stash} = {} });
    return $c;
}

subtest 'Subscription role attribute & method test' => sub {
    my $c      = mock_c();
    my $worker = new_ok(
        'Binary::WebSocketAPI::v3::Subscription::Example1' => [
            c    => $c,
            args => {},
        ]);
    like($worker->uuid, qr/^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$/, 'There is a uuid');
    is($worker->abbrev_class, 'Example1', 'abbrev class correct');
    is($worker->stats_name, 'bom_websocket_api.v_3.example1_subscriptions');
};

subtest 'Subscription class general test' => sub {
    my $c      = mock_c();
    my $worker = new_ok(
        Example1 => [
            c    => $c,
            args => {},
        ]);
    my $subscription_callback_called;
    is_oneref($worker->c, 'c has refcount 1');
    is($worker->status, undef, 'subscription still not defined');
    $worker->subscribe(sub { $subscription_callback_called = shift->channel });
    weaken(my $status = $worker->status);
    is_oneref($worker, 'worker has refcount 1');
    is(@subscription_requests, 1, 'have a single Redis subscription request');
    isa_ok($status, 'Future');
    ok(!$status->is_ready,             'subscription starts out unstatus');
    ok(!$subscription_callback_called, "subscription callback not called yet");
    {
        my $req = shift @subscription_requests
            or die 'no subscription request queued';
        cmp_deeply($req->[0], [$worker->channel], 'channel parameter was correct');
        lives_ok {
            $req->[1]->();
        }
        'can run callback with no exceptions';
        ok($worker->status->is_done, 'subscription is now done')
            or die 'subscription invalid';
        is($subscription_callback_called, $worker->channel, 'the subscription callback is called, and can visit worker');
    }
    is_oneref($worker, 'worker still has refcount 1');
    isa_ok(my $on_message = $callbacks{message}, 'CODE')
        or die 'no on_message callback';
    is(@Example1::MESSAGES, 0, 'start with no messages');
    is(@Example1::ERRORS,   0, 'no errors either');
    $log->clear;
    lives_ok {
        $on_message->(undef, encode_json_utf8({data => 'here'}) => 'NoSuchChannel');
    }
    'can trigger message with no failures';
    is(@Example1::MESSAGES, 0, 'Still no messages');
    is(@Example1::ERRORS,   0, 'no errors in Example1');
    $log->contains_only_ok(qr/Had a message for channel \[NoSuchChannel\]/, 'should emit an error message');
    lives_ok {
        $on_message->(undef, encode_json_utf8({data => 'here'}) => $worker->channel);
    }
    'can trigger message with no failures';
    is(@Example1::MESSAGES, 1, 'now have one message received');
    is(@Example1::ERRORS,   0, 'no errors yet');
    @Example1::MESSAGES = ();
    lives_ok {
        $on_message->(undef, encode_json_utf8({error => {code => 'Testing'}}) => $worker->channel);
    }
    'can trigger message with error';
    is(@Example1::MESSAGES, 1, 'still have one message received');
    is(@Example1::ERRORS,   1, 'but now also have an error');
    undef $worker;
    ok($status, 'status future is still there, because there is a ref in the redis unsubscribe callback');

    $log->clear;
    lives_ok {
        $on_message->(undef, encode_json_utf8({data => 'here'}) => 'example1');
    }
    'can trigger message with no failures';
    $log->empty_ok('should not emit an error message during the unsubscribing phrase');

    is(@unsubscription_requests, 1, 'There is an unsubscribe request');
    my $unsubscribe = shift @unsubscription_requests;
    is($unsubscribe->[0][0], 'example1', 'unsubscribe example1');
    $unsubscribe->[1]->();
    undef $unsubscribe;
    ok(!$status, 'Now status is destroyed');
    $log->clear;
    lives_ok {
        $on_message->(undef, encode_json_utf8({data => 'here'}) => 'example1');
    }
    'can trigger message with no failures';

    $log->contains_only_ok(qr/Had a message for channel \[example1\]/, 'should emit an error message');

    done_testing;
};

subtest "multi subscription to one channel" => sub {
    my $c = mock_c();
    @Example1::MESSAGES = ();
    my $example11 = new_ok(
        Example1 => [
            c    => $c,
            args => {},
        ]);
    my $example12 = new_ok(
        Example1 => [
            c    => $c,
            args => {},
        ]);

    my $example13 = new_ok(
        Example1 => [
            c    => $c,
            args => {},
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
    isa_ok(my $on_message = $callbacks{message}, 'CODE')
        or die 'no on_message callback';
    is(@Example1::MESSAGES, 0, 'start with no messages');
    $on_message->(undef, encode_json_utf8({data => 'msg1'}) => $example11->channel);
    my @addrs =
        (sort { $a <=> $b } (refaddr($example11), refaddr($example12)));
    is_deeply([sort { $a->[0] <=> $b->[0] } @Example1::MESSAGES], [map { [$_, {data => 'msg1'}] } @addrs], '2 worker received message');
    @Example1::MESSAGES = ();
    $example13->subscribe(sub { push @subscribe_callback_called, 'example13' });
    is_deeply(\@subscribe_callback_called, [qw(example13)], 'example 13 called at once subscribe cb called');
    is(@subscription_requests, 0, 'new subscription will not make real new subscription to redis');
    lives_ok {
        $on_message->(undef, encode_json_utf8({data => 'msg2'}) => $example11->channel);
    }
    'message can be processed';
    @addrs = (sort { $a <=> $b } (@addrs, refaddr($example13)));

    @Example1::MESSAGES = ();
    lives_ok { $example13->subscribe() } 'Maybe one worker will subscribe many times by mistake, but dont worry';
    lives_ok {
        $on_message->(undef, encode_json_utf8({data => 'msg3'}) => $example11->channel);
    }
    'message can still be processed';
    is_deeply([sort { $a->[0] <=> $b->[0] } @Example1::MESSAGES], [map { [$_, {data => 'msg3'}] } @addrs], '3 worker received message');

    my $example21 = new_ok(
        Example2 => [
            c    => $c,
            args => {},
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
    lives_ok {
        $on_message->(undef, encode_json_utf8({data => 'msg4'}) => $example11->channel);
    }
    'message can still be processed';
    is_deeply(\@Example1::MESSAGES, [[refaddr($example11), {data => 'msg4'}]], 'only one worker received message now');
    undef $example11;
    is(@unsubscription_requests, 1, 'This is the last client. so redis will receive the unsubscribe request');
    $req = shift @unsubscription_requests;
    is($req->[0][0], 'example1', 'unsubscribe example1');
    @Example1::MESSAGES = ();
    lives_ok {
        $on_message->(undef, encode_json_utf8({data => 'msg5'}) => 'example1');
    }
    'message can still be processed';
    is(@Example1::MESSAGES, 0, 'no message sent out because no receiver');
    my $example14 = new_ok(
        Example1 => [
            c    => $c,
            args => {},
        ]);
    $example14->subscribe();
    lives_ok {
        $on_message->(undef, encode_json_utf8({data => 'msg6'}) => 'example1');
    }
    'message can still be processed';
    is_deeply(\@Example1::MESSAGES, [[refaddr($example14), {data => 'msg6'}]], 'only one worker received message now');
    lives_ok { $req->[1]->() } 'unsubscribed callback executed';
    @Example1::MESSAGES = ();
    lives_ok {
        $on_message->(undef, encode_json_utf8({data => 'msg7'}) => 'example1');
    }
    'message can still be processed';
    is_deeply(\@Example1::MESSAGES, [[refaddr($example14), {data => 'msg7'}]], 'latest worker still can receive message now');
    subtest 'callback threshold' => sub {

        # test callback threshold
        @subscription_requests = ();
        my @subs;
        $log->clear;
        for (1 .. 1000) {
            push @subs,

                Example1->new(
                c           => $c,
                args        => {},
                channel_arg => 'channel1',
                );
            $subs[-1]->subscribe(sub { });
        }
        $log->does_not_contain_ok(qr/Too many callbacks/, 'no warnings logged');
        push @subs,
            Example1->new(
            c           => $c,
            args        => {},
            channel_arg => 'channel1',
            );
        $subs[-1]->subscribe(sub { });
        $log->contains_ok(qr/Too many callbacks in class Example1 channel channel1 queue/, 'too many callbacks in the channel1 queue');
        $log->clear;
        my $sub2 = Example1->new(
            c           => $c,
            args        => {},
            channel_arg => 'channel2',
        );
        $sub2->subscribe(sub { });
        $log->does_not_contain_ok(qr/Too many callbacks/, 'different channel has different queue, so channel channel2 will not have that warning');

        # execute callbacks
        my $req = shift @subscription_requests
            or die 'no subscription request queued';
        lives_ok {
            $req->[1]->();
        }
        "execute callback ok";
        for (1 .. 2000) {
            push @subs,

                Example1->new(
                c           => $c,
                args        => {},
                channel_arg => 'channel1',
                );
            $subs[-1]->subscribe(sub { });
        }
        $log->does_not_contain_ok(qr/Too many callbacks/, 'No warning now because the callbacks are not blocked.');
        done_testing;
    };

    done_testing;
};

subtest 'registering' => sub {
    my $c      = mock_c();
    my $worker = new_ok(
        Example1 => [
            c    => $c,
            args => {},
        ]);

    ok(!Example1->get_by_class($c), 'no subscription got because it is not registered yet');
    ok(!Example1->get_by_uuid($c, $worker->uuid), 'no subscription got because it is not regtistered yet');
    ok(!$worker->already_registered, 'this channel not registered yet');
    lives_ok { $worker->register; } 'register work';
    is_deeply([Example1->get_by_class($c)], [$worker], 'find this subscription because it is registered now');
    is(Example1->get_by_uuid($c, $worker->uuid), $worker, 'find subscription because it is regtistered now');
    ok($worker->already_registered, 'this channel not registered yet');
    is_deeply(
        $c->stash,
        {
            channels     => {Example1      => {example1 => $worker}},
            uuid_channel => {$worker->uuid => $worker}
        },
        'register result ok'
    );
    is_refcount($worker, 2, 'register will create a new ref on worker');
    my $worker2 = new_ok(
        Example1 => [
            c    => $c,
            args => {},
        ]);

    is($worker2->already_registered, $worker, 'has already a registered worker');
    is($worker2->register,           $worker, 'register will return the previous registered worker');
    is_deeply([sort Example1->get_by_class($c)], [sort ($worker)], 'There is no worker2 because it is registered by previous worker');
    ok(!Example1->get_by_uuid($c, $worker2->uuid), 'Cannot find this subscription because it is not registered');
    my $worker3 = new_ok(
        Example1 => [
            c    => $c,
            args => {subchannel => 2},
        ]);
    ok(!$worker3->already_registered, 'has not  register such work with subchannel 2');
    $worker3->register;
    is(scalar $worker3->get_by_class($c), 2, 'has 2 subscription in this class');
    is(Example1->get_by_uuid($c, $worker3->uuid), $worker3, 'get_by_uuid worker');
    is_deeply([sort Example1->get_by_class($c)], [sort ($worker, $worker3)], 'there are only 2 registered workers');

    lives_ok { Example1->unregister_by_uuid($c, $worker3->uuid) } 'unregister by uuid worker';
    ok(!Example1->get_by_uuid($c, $worker3->uuid), 'get_by_uuid cannot find this worker now ');
    is_deeply([sort Example1->get_by_class($c)], [sort ($worker)], 'there are only 1 registered worker now');
    lives_ok { $worker->unregister } 'unregsiter work';
    is_oneref($worker, 'unregister will reduce one ref');
    is_deeply(
        $c->stash,
        {
            channels     => {},
            uuid_channel => {}
        },
        'unregsiter result ok'
    );
    ok(!Example1->get_by_class($c), 'there is no registered worker now');

    # set uuid_channel by hand to check that the item will be deleted when subscription object destroyed
    weaken($c->stash->{uuid_channel}{$worker->uuid} = $worker);
    undef $worker;
    ok(!$c->stash->{uuid_channel}->%*, 'the item we set by hand was deleted by subscription DEMOLISH');
};

{
    # clean up by unsubscribing everything
    my $count = scalar @unsubscription_requests;
    while ($count > 0) {
        my $unsubscribe = shift @unsubscription_requests;
        $unsubscribe->[1]->();
        undef $unsubscribe;
        --$count;
    }
}

{

    package TransactionSubscription;
    use Moo;
    use Test::More;
    with 'Binary::WebSocketAPI::v3::Subscription';
    our @MESSAGES;
    our @ERRORS;
    has channel_arg => (is => 'ro');
    sub channel { shift->channel_arg // 'transactionSubscription' }

    sub handle_message {
        my $self = shift;
        push @MESSAGES, [Scalar::Util::refaddr($self), @_];
    }

    sub handle_error {
        my $self = shift;
        push @ERRORS, [Scalar::Util::refaddr($self), @_];
        return $_[-1];
    }

    sub _unique_key {
        my $self = shift;
        return $self->channel . ($self->args->{subchannel} // '');
    }

    sub subscription_manager {
        return Binary::WebSocketAPI::v3::SubscriptionManager->redis_transaction_manager();
    }
}

{

    package Binary::WebSocketAPI::v3::Subscription::TransactionSubscription;
    use Moo;
    extends 'TransactionSubscription';
}

subtest 'Transaction subscription role attribute & method test' => sub {
    my $c      = mock_c();
    my $worker = new_ok(
        'Binary::WebSocketAPI::v3::Subscription::TransactionSubscription' => [
            c    => $c,
            args => {},
        ]);
    like($worker->uuid, qr/^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$/, 'There is a uuid');
    is($worker->abbrev_class, 'TransactionSubscription', 'abbrev class correct');
    is($worker->stats_name, 'bom_websocket_api.v_3.transactionsubscription_subscriptions');
};

subtest 'Subscription class transaction test' => sub {
    my $c      = mock_c();
    my $worker = new_ok(
        TransactionSubscription => [
            c    => $c,
            args => {},
        ]);
    my $subscription_callback_called;
    is_oneref($worker->c, 'c has refcount 1');
    is($worker->status, undef, 'subscription still not defined');
    $worker->subscribe(sub { $subscription_callback_called = shift->channel });
    weaken(my $status = $worker->status);
    is_oneref($worker, 'worker has refcount 1');
    is(@subscription_requests, 2, 'have two Redis-one general and other transaction-subscription request');
    isa_ok($status, 'Future');
    ok(!$status->is_ready,             'subscription starts out unstatus');
    ok(!$subscription_callback_called, "subscription callback not called yet");
    {
        my $req = shift @subscription_requests
            or die 'no subscription request queued';
        # transaction one is the second one
        $req = shift @subscription_requests
            or die 'no transaction subscription request queued';

        cmp_deeply($req->[0], [$worker->channel], 'channel parameter was correct');
        lives_ok {
            $req->[1]->();
        }
        'can run callback with no exceptions';
        ok($worker->status->is_done, 'subscription is now done')
            or die 'subscription invalid';
        is($subscription_callback_called, $worker->channel, 'the subscription callback is called, and can visit worker');
    }
    is_oneref($worker, 'worker still has refcount 1');
    isa_ok(my $on_message = $callbacks{message}, 'CODE')
        or die 'no on_message callback';
    is(@TransactionSubscription::MESSAGES, 0, 'start with no messages');
    is(@TransactionSubscription::ERRORS,   0, 'no errors either');
    $log->clear;
    lives_ok {
        $on_message->(undef, encode_json_utf8({data => 'here'}) => 'NoSuchChannel');
    }
    'can trigger message with no failures';
    is(@TransactionSubscription::MESSAGES, 0, 'Still no messages');
    is(@TransactionSubscription::ERRORS,   0, 'no errors in TransactionSubscription');
    $log->contains_only_ok(qr/Had a message for channel \[NoSuchChannel\]/, 'should emit an error message');
    lives_ok {
        $on_message->(undef, encode_json_utf8({data => 'here'}) => $worker->channel);
    }
    'can trigger message with no failures';
    is(@TransactionSubscription::MESSAGES, 1, 'now have one message received');
    is(@TransactionSubscription::ERRORS,   0, 'no errors yet');
    @TransactionSubscription::MESSAGES = ();
    lives_ok {
        $on_message->(undef, encode_json_utf8({error => {code => 'Testing'}}) => $worker->channel);
    }
    'can trigger message with error';
    is(@TransactionSubscription::MESSAGES, 1, 'still have one message received');
    is(@TransactionSubscription::ERRORS,   1, 'but now also have an error');
    undef $worker;
    ok($status, 'status future is still there, because there is a ref in the redis unsubscribe callback');

    $log->clear;
    lives_ok {
        $on_message->(undef, encode_json_utf8({data => 'here'}) => 'transactionSubscription');
    }
    'can trigger message with no failures';
    $log->empty_ok('should not emit an error message during the unsubscribing phrase');

    is(@unsubscription_requests, 1, 'There is an unsubscribe request');
    my $unsubscribe = shift @unsubscription_requests;
    is($unsubscribe->[0][0], 'transactionSubscription', 'unsubscribe transactionSubscription');
    $unsubscribe->[1]->();
    undef $unsubscribe;
    ok(!$status, 'Now status is destroyed');
    $log->clear;
    lives_ok {
        $on_message->(undef, encode_json_utf8({data => 'here'}) => 'transactionSubscription');
    }
    'can trigger message with no failures';

    $log->contains_only_ok(qr/Had a message for channel \[transactionSubscription\]/, 'should emit an error message');

    done_testing;
};

done_testing();

