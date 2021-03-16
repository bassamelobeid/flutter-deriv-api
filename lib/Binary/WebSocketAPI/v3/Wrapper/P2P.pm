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
use Binary::WebSocketAPI::v3::Subscription::P2P::Advertiser;
use Binary::WebSocketAPI::v3::Subscription::P2P::Advert;
use Binary::WebSocketAPI::v3::Subscription::P2P::Order;

sub subscribe_orders {
    my ($c, $rpc_response, $req_storage) = @_;

    my $args     = $req_storage->{args};
    my $msg_type = $req_storage->{msg_type};

    if ($rpc_response->{error}) {
        return $c->new_error($msg_type, $rpc_response->{error}{code}, $rpc_response->{error}{message_to_client});
    }

    my $result = {
        msg_type  => $msg_type,
        $msg_type => $rpc_response,
        defined $args->{req_id} ? (req_id => $args->{req_id}) : (),
    };

    return $result unless $args->{subscribe} and $c->stash('loginid');

    my $order_id =
          $msg_type eq 'p2p_order_info'   ? $args->{id}
        : $msg_type eq 'p2p_order_create' ? $rpc_response->{id}
        :                                   undef;

    my $sub = Binary::WebSocketAPI::v3::Subscription::P2P::Order->new(
        c        => $c,
        args     => $args,
        loginid  => $c->stash('loginid'),
        broker   => $c->stash('broker'),
        country  => $c->stash('country'),
        currency => $c->stash('currency'),
        ($order_id ? (order_id => $order_id) : ()),
    );

    if ($order_id && $sub->already_registered) {
        return $c->new_error($msg_type, 'AlreadySubscribed', $c->l('You are already subscribed to p2p order id [_1].', $order_id));
    }

    if ($sub->already_registered) {
        return $c->new_error($msg_type, 'AlreadySubscribed', $c->l('You are already subscribed to p2p order list', $order_id));
    }

    $sub->register;
    $sub->subscribe;
    $result->{subscription}{id} = $sub->uuid;
    return $result;
}

sub subscribe_advertisers {
    my ($c, $rpc_response, $req_storage) = @_;

    my $args     = $req_storage->{args};
    my $msg_type = $req_storage->{msg_type};

    if ($rpc_response->{error}) {
        return $c->new_error($msg_type, $rpc_response->{error}{code}, $rpc_response->{error}{message_to_client});
    }

    my $result = {
        msg_type  => $msg_type,
        $msg_type => $rpc_response,
        defined $args->{req_id} ? (req_id => $args->{req_id}) : (),
    };

    return $result unless $args->{subscribe} and $c->stash('loginid');

    my $advertiser_id = $rpc_response->{id};

    return $result unless $advertiser_id;

    my $sub = Binary::WebSocketAPI::v3::Subscription::P2P::Advertiser->new(
        c             => $c,
        args          => $args,
        broker        => $c->stash('broker'),
        loginid       => $c->stash('loginid'),
        advertiser_id => $advertiser_id,
    );

    if ($sub->already_registered) {
        return $c->new_error($msg_type, 'AlreadySubscribed', $c->l('You are already subscribed to p2p advertiser id [_1].', $advertiser_id));
    }

    $sub->register;
    $sub->subscribe;
    $result->{subscription}{id} = $sub->uuid;
    return $result;
}

1;
