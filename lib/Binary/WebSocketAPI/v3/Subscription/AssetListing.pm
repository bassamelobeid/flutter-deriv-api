package Binary::WebSocketAPI::v3::Subscription::AssetListing;

use strict;
use warnings;
no indirect;

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::AssetListing - The class that handle asset listing subcription channels

=head1 SYNOPSIS

    my $worker = Binary::WebSocketAPI::v3::Subscription::AssetListing->new(
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
    return Binary::WebSocketAPI::v3::SubscriptionManager->redis_asset_listing_manager();
}

=head2 _build_channel

Please refer to L<Binary::WebSocketAPI::v3::Subscription/channel>

=cut

sub _build_channel { return 'asset_listing::' . shift->symbol }

=head2 _unique_key

This method is used to find a subscription. Class name + _unique_key will be a
unique index of the subscription objects.

=cut

sub _unique_key {
    my $self = shift;
    my $key  = $self->symbol;
    $key .= ";" . $self->args->{req_id} if $self->args->{req_id};

    return $key;
}

=head2 _localize_symbol

This method is used to localize the symbol name

=cut

sub _localize_symbol {
    my ($self, $payload) = @_;
    my $response = {};

    my $assets = $payload->{mt5}->{assets};

    $_->{symbol} = $self->c->l($_->{symbol}) for $assets->@*;

    $response->{mt5} = {assets => $assets};

    return $response;
}

=head2 handle_message

Please refer to L<Binary::WebSocketAPI::v3::Subscription/handle_message>

=cut

sub handle_message {
    my ($self, $payload) = @_;

    my $type             = 'trading_platform_asset_listing';
    my $c                = $self->c;
    my $localize_payload = $self->_localize_symbol($payload);

    my $results = {
        msg_type     => $type,
        $type        => {$localize_payload->%*,},
        subscription => {id => $self->uuid},
    };

    $c->send({json => $results}, {args => $self->args});
    return;
}

1;

