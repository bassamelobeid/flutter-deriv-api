package Binary::WebSocketAPI::v3::Subscription::AssetListing;

use strict;
use warnings;
use Math::Cartesian::Product;
no indirect;

=head1 NAME

Binary::WebSocketAPI::v3::Subscription::AssetListing - The class that handle asset listing subcription channels

=head1 SYNOPSIS

    my $worker = Binary::WebSocketAPI::v3::Subscription::AssetListing->new(
        c               => $c,
        type            => $type,
        args            => $args,
        normalized_args => $normalized_args,
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

=head2 normalized_args

=cut

has normalized_args => (
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

sub _build_channel { return 'asset_listing' }

=head2 _unique_key

This method is used to find a subscription. Class name + _unique_key will be a
unique index of the subscription objects.

=cut

sub _unique_key {
    my $self = shift;
    local *_norm = sub {
        my $in = $_;
        return join ',', sort map { _norm($_) } $in->@*                if (ref $in eq 'ARRAY');
        return join '|', map      { _norm($in->$_) } sort keys $in->%* if (ref $in eq 'HASH');
        return $in;
    };
    return _norm($self->normalized_args);
}

=head2 handle_message

Please refer to L<Binary::WebSocketAPI::v3::Subscription/handle_message>

=cut

sub handle_message {
    my ($self, undef) = @_;

    my $type = $self->type;
    my $c    = $self->c;

    # The message doesn't contain any meaningful information,
    # thus we just drop it and call RPC once again,
    # to delegate all the request handling logic to it.
    $c->call_rpc({
            method      => $type,
            msg_type    => $type,
            args        => $self->normalized_args,
            call_params => {
                token    => $c->stash('token'),
                language => $c->stash('language'),
            },
            response => sub {
                my ($rpc_response, $api_response, $req_storage) = @_;
                $req_storage->{args}          = $self->args;
                $api_response->{subscription} = {id => $self->uuid};
                $c->send({json => $api_response}, $req_storage);
                return $api_response;
            }
        });
    return;
}

1;

