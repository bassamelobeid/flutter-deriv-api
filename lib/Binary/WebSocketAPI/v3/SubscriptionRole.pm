package Binary::WebSocketAPI::v3::SubscriptionRole;

use strict;
use warnings;

=head1 NAME

Binary::WebSocketAPI::v3::SubscriptionRole - base class for subscriptions handled by Redis

=head1 DESCRIPTION

This module is the common interface for subscription-related tasks such as transactions and pricing

=cut

use Future;
use Future::Mojo;
use curry::weak;

use Binary::WebSocketAPI::v3::Instance::Redis qw(shared_redis);
use JSON::MaybeUTF8 qw(:v1);
use Binary::WebSocketAPI::v3::SubscriptionManager;
use Scalar::Util qw(blessed weaken);
use Log::Any qw($log);
use Try::Tiny;
use DataDog::DogStatsd::Helper qw(stats_inc stats_dec);
use Moo::Role;

=head2 subscription

The underlying subscription

=cut

has subscription => (
    is      => 'rw',
    default => undef,
);

=head2 c

=cut

has c => (
    is       => 'ro',
    weak_ref => 1,
    required => 1,
);

=head2 args

=cut

has args => (
    is       => 'ro',
    required => 1,
);

=head2 request_storage

=cut

has request_storage => (
    is       => 'ro',
    required => 0,
);

=head2 uuid

=cut

#TODO move uuid generator to here
has uuid => (
    is       => 'ro',
    required => 1,
);

=head1 METHODS

=cut

=head2 channel

build and return channel name

=cut

requires 'channel';

=head2 handle_message

Process the messages

=cut

requires 'handle_message';

=head2 class

The class name of the object.

=cut

has class => (is => 'lazy');

sub _build_class {
    my $self = shift;
    return blessed($self);
}

=head2

the name that will be used in stats_* function

=cut

has stats_name => (is => 'lazy');

sub _build_stats_name {
    my ($self) = @_;
    $self->class =~ /(\w+)$/;
    my $package = lc($1);
    return "bom_websocket_api.v_3.${package}_subscriptions";
}

=head2 handle_error

process the error

=cut

sub handle_error {
    my ($self, $err, $msg) = @_;
    $log->errorf("error happened when processing message: %s from %s, module %s, channel %s", $err, $msg, $self->class, $self->channel);
    return;
}

=head2 subscription_manager

The SubscriptionManager instance that will manage this worker

=cut

requires 'subscription_manager';

=head2 subscribe

subscribe the streamer.

=cut

sub subscribe {
    my ($self, $callback) = @_;

    $self->subscription($self->subscription_manager->subscribe($self)) unless $self->subscription;
    return $self->subscription unless $callback;

    my $class      = $self->class;
    my $channel    = $self->channel;
    my $wrapped_cb = sub {
        my $self = shift;
        # might be a case where client already disconnected before
        # successful redis subscription
        unless ($self) {
            $log->warnf("worker gone when processing callback of class $class, channel $channel");
            return;
        }
        try {
            $callback->($self);
        }
        catch {
            $log->warnf("callback invocation error during redis subscription to class $class, channel $channel: $_");
        };
    };
    $self->status->on_done($self->$curry::weak($wrapped_cb));
    # NOTICE: here the internal variable `callbacks` of `Future` is checked. Maybe one day that interval variable will be changed and this line be affected.
    $log->warnf("To many callbacks in class %s channel ($channel) queue, possible redis connection issue", $self->class)
        if (@{$self->status->{callbacks} // []} > 1000);
    return $self->subscription;
}

=head2 status

A L<Future> representing the subscription state - resolved if the subscription
is active.

    $subscription->status->is_done

=cut

sub status {
    my ($self) = @_;
    return $self->subscription ? $self->subscription->status : undef;
}

=head2 unsubscrube

unsubscribe the channel

=cut

sub unsubscribe {
    my $self = shift;
    return $self->subscription_manager->unsubscribe($self->subscription);
}

=head1 METHODS - Construction/destruction

=head2 BUILD

record some stats

=cut

sub BUILD {
    my $self = shift;
    stats_inc($self->stats_name . '.instances');
    return $self;
}

=head2 DEMOLISH

On cleanup, will notify the manager in case it needs to unsubscribe.

=cut

sub DEMOLISH {
    my ($self, $global) = @_;
    $log->tracef("Destroying the worker %s channel %s", $self->class, $self->channel);
    stats_dec($self->stats_name . '.instance');
    return if $global;
    return unless $self->subscription;
    $self->unsubscribe();
    return;
}

1;

