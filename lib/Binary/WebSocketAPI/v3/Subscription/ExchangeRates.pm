package Binary::WebSocketAPI::v3::Subscription::ExchangeRates;

use strict;
use warnings;
no indirect;

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::ExchangeRates - The class that handle exchange rates subcription channels

=head1 SYNOPSIS

    my $worker = Binary::WebSocketAPI::v3::Subscription::ExchangeRates->new(
        c          => $c,
        type       => $type,
        args       => $args,
        symbol     => $symbol,
    );

    $worker->subscribe($callback);  # do subscribe and execute a callback after subscribed.
    $worker->unsubscribe;
    undef $worker; # Destroying the object will also call unsubscribe method

=head1 DESCRIPTION

This module deals with the exchange rates channel subscriptions. We can subscribe one channel
as many times as we want. L<Binary::WebSocketAPI::v3::SubscriptionManager> will
subscribe that channel on redis server only once and this module will register
information that will be fetched when the message arrive. So to avoid duplicate
subscription, we can store the worker in the stash with the unique key.

Please refer to L<Binary::WebSocketAPI::v3::Subscription>

=cut

use Scalar::Util qw(looks_like_number);
use List::Util   qw(first);
use Log::Any     qw($log);
use Moo;
with 'Binary::WebSocketAPI::v3::Subscription';

use namespace::clean;

=head1 ATTRIBUTES

=head2 symbol

=cut

has symbol => (
    is       => 'ro',
    required => 1,
);

=head2 type

=cut

has type => (
    is       => 'ro',
    required => 1,
);

=head2 subscription_manager

Please refer to L<Binary::WebSocketAPI::v3::Subscription/subscription_manager>

=cut

sub subscription_manager {
    return Binary::WebSocketAPI::v3::SubscriptionManager->redis_exchange_rates_manager();
}

=head2 _build_channel

Please refer to L<Binary::WebSocketAPI::v3::Subscription/channel>

=cut

sub _build_channel { return 'exchange_rates::' . shift->symbol }

=head2 _unique_key

This method is used to find a subscription. Class name + _unique_key will be a
unique index of the subscription objects.

=cut

sub _unique_key {
    my $self = shift;

    return $self->symbol . ";" . $self->type;
}

=head2 handle_message

Please refer to L<Binary::WebSocketAPI::v3::Subscription/handle_message>

=cut

sub handle_message {
    my ($self, $payload) = @_;

    my $type = 'exchange_rates';
    my $c    = $self->c;

    unless ($c->tx) {
        $self->unregister;
        return;
    }

    my $results = {
        msg_type     => $type,
        $type        => {$payload->%*,},
        subscription => {id => $self->uuid},
    };

    $c->send({json => $results}, {args => $self->args});
    return;
}

1;

