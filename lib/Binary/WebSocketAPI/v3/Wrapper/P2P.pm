package Binary::WebSocketAPI::v3::Wrapper::P2P;

use strict;
use warnings;

=head1 NAME

Binary::WebSocketAPI::v3::Wrapper::P2P - provides handlers for specific behaviour
relating to the P2P cashier

=head1 DESCRIPTION

This module mostly provides subscription hooks for updates on the various P2P entities.

=cut

no indirect;

use Binary::WebSocketAPI::v3::Subscription;
use Binary::WebSocketAPI::v3::Subscription::P2P::Agent;
use Binary::WebSocketAPI::v3::Subscription::P2P::Offer;
use Binary::WebSocketAPI::v3::Subscription::P2P::Order;

sub subscribe_offer {
    my ($c, $req_storage) = @_;
    my $args = $req_storage->{args};
    my $sub  = Binary::WebSocketAPI::v3::Subscription::P2P::Offer->new(
        c    => $c,
        type => 'p2p_offer',
        args => $args,
    );
    $sub->register;
    $sub->subscribe;
    $req_storage->{p2p_offer_channel_id} = $sub->uuid;
    return undef;
}

sub subscribe_order {
    my ($c, $req_storage) = @_;
    my $args = $req_storage->{args};
    my $sub  = Binary::WebSocketAPI::v3::Subscription::P2P::Order->new(
        c    => $c,
        type => 'p2p_order',
        args => $args,
    );
    $sub->register;
    $sub->subscribe;
    $req_storage->{p2p_order_channel_id} = $sub->uuid;
    return undef;
}

sub subscribe_agent {
    my ($c, $req_storage) = @_;
    my $args = $req_storage->{args};
    my $sub  = Binary::WebSocketAPI::v3::Subscription::P2P::Agent->new(
        c    => $c,
        type => 'p2p_agent',
        args => $args,
    );
    $sub->register;
    $sub->subscribe;
    $req_storage->{p2p_agent_channel_id} = $sub->uuid;
    return undef;
}

sub subscribe_chat {
    my ($c, $req_storage) = @_;
    my $args = $req_storage->{args};
    my $sub  = Binary::WebSocketAPI::v3::Subscription::P2P::Chat->new(
        c    => $c,
        type => 'p2p_chat',
        args => $args,
    );
    $sub->register;
    $sub->subscribe;
    $req_storage->{p2p_chat_channel_id} = $sub->uuid;
    return undef;
}

1;
