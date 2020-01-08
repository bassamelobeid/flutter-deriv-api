package Binary::WebSocketAPI::v3::SubscriptionManager;

use strict;
use warnings;
no indirect;

use feature qw(state);
use Moo;
use curry;
use curry::weak;
use Future::Mojo;
use Try::Tiny;
use Log::Any qw($log);
use Scalar::Util qw(refaddr weaken);
use DataDog::DogStatsd::Helper qw(stats_inc stats_dec);
use Binary::WebSocketAPI::v3::Subscription;
use Binary::WebSocketAPI::v3::Instance::Redis qw(
    redis_feed_master
    redis_pricer
    redis_transaction
    redis_p2p
);

use namespace::clean;

=head1 NAME

Binary::WebSocketAPI::v3::SubscriptionManager - maintains Redis
subscriptions.

=head1 DESCRIPTION

This module is how the code requests and discards subscriptions.
Multiple clients may want to subscribe to the same thing, the manager coordinates them

=cut

=head2 name

The object name, used to decide which redis server used.

=cut

has name => (
    is       => 'ro',
    required => 1,
);

=head2 channels

Mapping from channel names to L<Future> instances representing the Redis
subscription state (resolved once connected).

=cut

has channels => (
    is      => 'ro',
    default => sub { return +{} });

=head2 channel_subscriptions

A hashref of C<< channel name => subscription >> instances.

=cut

has channel_subscriptions => (
    is      => 'ro',
    default => sub { return +{} });

=head2 channel_unsubscribing

When unsubscribing a channel, it will do like this:

1. clear cached information like subscription object.
2. do redis unsubscribing action

After step 1 and before step 2, messages still can be received, but we have no handler to process them.
So this hash indicate that the channel is unsubscribing and the message can be ignored.

Please refer to L<unsubscribe> and L<on_message>

=cut

has channel_unsubscribing => (
    is      => 'ro',
    default => sub { return +{} });

=head2 redis

return redis instance

=cut

my $config = {
    redis_feed_master_manager => sub { return redis_feed_master() },
    redis_pricer_manager      => sub { return redis_pricer() },
    redis_transaction_manager => sub { return redis_transaction() },
    redis_p2p_manager         => sub { return redis_p2p() }
};

sub redis {
    my $self  = shift;
    my $redis = $config->{$self->name}->();
    return $redis;
}

=head2 subscribe

Returns a L<Future> instance that represents the status of subscription.

=cut

sub subscribe {
    my ($self, $subscription) = @_;
    my $channel    = $subscription->channel;
    my $stats_name = $subscription->stats_name;
    my $class      = $subscription->class;
    stats_inc("$stats_name.clients");
    $log->tracef('Subscribing %s channel %s in pid %i', $class, $channel, $$);
    my $f = (
        $self->channels->{$channel} //= do {
            my $f = Future::Mojo->new->set_label('RedisSubscription[' . $channel . ']');
            $self->redis->subscribe(
                [$channel],
                sub {
                    my (undef, $err) = @_;
                    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
                    # We can do nothing useful if we are already shutting down
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
    weaken($self->channel_subscriptions->{$channel}{refaddr($subscription)} = $subscription);

    return $f;
}

=head2 unsubscribe

unsubscribe a streamer

=cut

sub unsubscribe {
    my ($self, $subscription) = @_;
    my $channel      = $subscription->channel;
    my $class        = $subscription->class;
    my $stats_name   = $subscription->stats_name;
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
    # variables, and leave the state clean for any future subscriptions that
    # may be received while we're awaiting Redis confirmation of unsubscription.
    # See `t/subscription.t` for test coverage here.
    my $f                     = delete $self->channels->{$channel};
    my $channel_unsubscribing = $self->channel_unsubscribing;
    $channel_unsubscribing->{$channel} = 1;
    delete $self->channel_subscriptions->{$channel};
    $self->redis->unsubscribe(
        [$channel],
        sub {
            my (undef, $err) = @_;
            # We can do nothing useful if we are already shutting down
            return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
            $log->tracef('Unsubscribed from redis server for %s channel %s in pid %i', $class, $channel, $$);
            delete $channel_unsubscribing->{$channel};
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
    $self->redis->on(message => $self->curry::weak::on_message);
    return;
}

=head2 on_message

The function that will attach onto redis server. This function will call on_message functions of all subscriptions

=cut

sub on_message {
    my ($self, $redis, $message, $channel) = @_;
    if (my $entry = $self->channel_subscriptions->{$channel}) {
        # The $entry hash could be modified while we are looping over it
        # In order to avoid a situation like: https://perldoc.pl/perldiag#Use-of-freed-value-in-iteration
        # since keys and values subs might leads to issues we will "Capture" the hash keys at the point of time
        # Maybe during the iteration time, the element has been deleted, so we should check again before process the message
        # when we received the message, also please see:
        # https://trello.com/c/Qm0MSFBD/#comment-5be403a7dceb540885f49d2a
        my @client_subscriptions = values %$entry;
        $_ && $_->process($message) for @client_subscriptions;
    } elsif (!exists($self->channel_unsubscribing->{$channel})) {
        $log->errorf('Had a message for channel [%s] but that channel is not subscribed', $channel);
        stats_inc("SubscriptionManager.UnsubscribedMsg");
    }
    return;
}

=head2 instances of this class

=cut

# Autopopulate remaining methods
for my $name (sort keys %$config) {
    my $instance;
    my $code = sub {
        my $class = shift;
        return $instance //= $class->new(name => $name);
    };
    {
        no strict 'refs';
        *$name = $code
    }
}

1;

