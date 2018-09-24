package Binary::WebSocketAPI::v3::SubscriptionManager;

use strict;
use warnings;
use Scalar::Util qw(weaken);
use DataDog::DogStatsd::Helper qw(stats_inc stats_dec);

=head1 NAME

Binary::WebSocketAPI::v3::SubscriptionManager - maintains Redis 
subscriptions.

=head1 DESCRIPTION

This module is how the code requests and discards subscriptions.
Multiple clients may want to subscribe to the same thing, the manager coordinates those

=cut

no indirect;
use feature qw(state);
use Moo;
use curry;
use Future::Mojo;
use Try::Tiny;
use Log::Any qw($log);
use Scalar::Util qw(refaddr weaken);
use Binary::WebSocketAPI::v3::Subscription;
use Binary::WebSocketAPI::v3::Instance::Redis qw(shared_redis redis_pricer);

=head2 redis

The L<Mojo::Redis2> instance that will be used.

=cut

has redis => (
    is => 'ro',
);

=head2 channels

Mapping from channel names to L<Future> instances representing the Redis
subscription state (resolved once connected).

=cut

has channels => (
    is => 'lazy',
);
sub _build_channels { return +{}; }

=head2

A hashref of C<< channel name => subscription >> instances.

=cut

has channel_subscriptions => (
    is => 'lazy',
);
sub _build_channel_subscriptions { return +{}; }

=head2 subscribe

Returns a L<Binary::WebSocketAPI::v3::Subscription> instance

=cut

sub subscribe {
    my ($self, $worker) = @_;
    my $channel    = $worker->channel;
    my $stats_name = $worker->stats_name;
    my $class      = $worker->class;
    stats_inc("$stats_name.clients");
    $log->tracef('Subscribing %s channel %s in pid %i', $class, $channel, $$);
    my $f = (
        $self->channels->{$channel} //= do {
            my $f = Future::Mojo->new->set_label('RedisSubscription[' . $channel . ']');
            $self->redis->subscribe(
                [$channel],
                sub {
                    my (undef, $err) = @_;
                    $log->tracef('Subscribed to redis server for %s channel %s in pid %i', $class, $channel, $$);
                    if ($err) {
                        $log->errorf("Failed Redis subscription for %s channel %s - %s", $class, $channel, $err);
                        stats_inc("$stats_name.instances.error");
                        $f->fail($err, redis => $channel);
                        return;
                    }
                    stats_inc("$stats_name.instances.success");
                    $f->done($channel);
                    return;
                });
            $f;
            }
    );
    my $sub = Binary::WebSocketAPI::v3::Subscription->new(
        channel => $channel,
        manager => $self,
        status  => $f,
        worker  => $worker,
    );
    weaken($self->channel_subscriptions->{$channel}{refaddr($sub)} = $sub);
    return $sub;
}

=head2 unsubscribe

unsubscribe a streamer

=cut

sub unsubscribe {
    my ($self, $subscription) = @_;
    my $channel      = $subscription->channel;
    my $class        = $subscription->worker->class;
    my $stats_name   = $subscription->worker->stats_name;
    my $subs         = $self->channel_subscriptions->{$channel};
    my $original_sub = delete $subs->{refaddr($subscription)} or do {
        $log->errorf('Request to unsubscribe for a %s subscription that never existed on channel [%s]', $class, $channel);
        return $self;
    };

    stats_dec("$stats_name.clients");
    my $remaining = 0 + keys %$subs;
    $log->tracef('Unsubscribed from %s channel %s, %d remaining, in pid %i', $class, $channel, $remaining, $$);
    return $self if $remaining;

    # We have to be careful about race conditions here: it's quite conceivable
    # that we'll hit a sequence such as:
    #
    # - ->subscribe, channel count now 1
    # - unsubscribe, channel count now 0
    # - start Redis unsubscription
    # - ->subscribe, Redis still has not confirmed
    # - start Redis subscription
    # - Redis unsubscription now completes
    #
    # This means we should clear out all our internal state first into lexical
    # variables, and leave the slate clean for any future subscriptions that
    # may be received while we're awaiting Redis confirmation of unsubscription.
    # See `t/subscription.t` for test coverage here.
    my $f = delete $self->channels->{$channel};
    delete $self->channel_subscriptions->{$channel};
    $self->redis->unsubscribe(
        [$channel],
        sub {
            my (undef, $err) = @_;
            $log->tracef('Unsubscribed from redis server for %s channel %s in pid %i', $class, $channel, $$);
            # May have had a sub/unsub sequence before Redis could finish the
            # initial subscription
            $f->cancel unless $f->is_ready;
            if ($err) {
                $log->warnf("Failed to stop %s subscription for channel %s due to error: $err", $class, $channel);
                stats_inc("$stats_name.unsubscribe.error");
                return;
            }
            stats_inc("$stats_name.unsubscribe.success");
            return;
        });
    return $self;
}

=head2 BUILD

Do some preparation.

=cut

sub BUILD {
    my ($self) = @_;
    $self->redis->on(
        message => $self->curry::weak::on_message,
        error   => sub { $log->errorf('Had an error from Redis: %s', join ' ', @_) },
    );
    return;
}

=head2 on_message

The function that will attach onto redis server. This function will call on_message functions of all subscriptions

=cut

sub on_message {
    my ($self, $redis, $message, $channel) = @_;
    if (my $entry = $self->channel_subscriptions->{$channel}) {
        foreach my $subscription (values %$entry) {
            $subscription->process($message);
        }
    } else {
        $log->errorf('Had a message for channel [%s] but that channel is not subscribed', $channel);
    }
    return;
}

=head2 instances of this class

=cut

my $config = {
    shared_redis_manager => shared_redis(),
    redis_pricer_manager => redis_pricer(),
};

# Autopopulate remaining methods
for my $name (sort keys %$config) {
    my $redis = $config->{$name};
    my $instance;
    my $code = sub {
        my $class = shift;
        return $instance //= $class->new(redis => $redis);
    };
    {
        no strict 'refs';
        *$name = $code
    }
}

1;

