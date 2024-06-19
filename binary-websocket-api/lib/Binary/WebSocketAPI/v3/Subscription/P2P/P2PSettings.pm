package Binary::WebSocketAPI::v3::Subscription::P2P::P2PSettings;

use strict;
use warnings;
no indirect;

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::P2P::P2PSettings - The class that handle p2p settings subcription channels

=head1 SYNOPSIS

    my $worker = Binary::WebSocketAPI::v3::Subscription::P2P::P2PSettings->new(
        c       => $c,
        args    => $args,
        country => $country;
    );

    $worker->subscribe();
    $worker->unsubscribe;
    undef $worker; # Destroying the object will also call unsubscribe method

=head1 DESCRIPTION

This module deals with the p2p settings subcription channels. We can subscribe one channel
as many times as we want. L<Binary::WebSocketAPI::v3::SubscriptionManager> will
subscribe that channel on redis server only once and this module will register
information that will be fetched when the message arrive. So to avoid duplicate
subscription, we can store the worker in the stash with the unique key.

Please refer to L<Binary::WebSocketAPI::v3::Subscription>

=cut

use Moo;
with 'Binary::WebSocketAPI::v3::Subscription';

=head1 ATTRIBUTES

=head2 country

Two letter uppercase country code that will be used part of channel name

=cut

has country => (
    is       => 'ro',
    required => 1,
);

=head1 METHODS

=head2 subscription_manager

The SubscriptionManager instance that will manage this worker

=cut

sub subscription_manager {
    return Binary::WebSocketAPI::v3::SubscriptionManager->redis_p2p_manager();
}

=head2 _build_channel

Build name of redis channel, which will be used for getting new events

=cut

sub _build_channel {
    my $self = shift;
    return join q{::} => ('NOTIFY', 'P2P_SETTINGS', uc($self->country));
}

=head2 _unique_key

This method is used to find a subscription.
Class name + _unique_key will be a unique per context index of the subscription objects.

=cut

sub _unique_key {
    my $self = shift;
    return $self->channel;
}

=head2 handle_message

=cut

sub handle_message {
    my ($self, $payload) = @_;
    my $c = $self->c;
    unless ($c->tx) {
        $self->unregister;
        return;
    }

    my $args = $self->args;
    $c->send({
            json => {
                msg_type => 'p2p_settings',
                echo_req => $args,
                (exists $args->{req_id})
                ? (req_id => $args->{req_id})
                : (),
                p2p_settings => $payload,
                subscription => {id => $self->uuid},
            }});
    return;
}

1;
