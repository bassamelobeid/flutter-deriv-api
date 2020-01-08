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
    my ($c, $rpc_response, $req_storage) = @_;

    my $args     = $req_storage->{args};
    my $msg_type = $req_storage->{msg_type};

    if ($rpc_response->{error}) {
        return $c->new_error($msg_type, $rpc_response->{error}{code}, $rpc_response->{error}{message_to_client});
    }

    my $brocker = delete $rpc_response->{P2P_SUBSCIPTION_BROKER_CODE};

    my $result = {
        msg_type  => $msg_type,
        $msg_type => $rpc_response,
        defined $args->{req_id} ? (req_id => $args->{req_id}) : (),
    };
    return $result unless $args->{subscribe};

    my $sub = Binary::WebSocketAPI::v3::Subscription::P2P::Order->new(
        c        => $c,
        args     => $args,
        broker   => $brocker,
        order_id => $rpc_response->{order_id},
    );

    if ($sub->already_registered) {
        return $c->new_error($msg_type, 'AlreadySubscribed', $c->l('You are already subscribed to p2p order id [_1].', $rpc_response->{order_id}));
    }

    $sub->register;
    $sub->subscribe;
    $result->{subscription}{id} = $sub->uuid;
    return $result;
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
