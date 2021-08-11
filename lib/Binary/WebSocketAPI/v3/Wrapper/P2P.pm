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

    return $result unless $args->{subscribe} and $c->stash('loginid') and $c->stash('broker') and $c->stash('country') and $c->stash('currency');

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

=head2 subscribe_adverts

Handle subscriptions for p2p_advert_info

=cut

sub subscribe_adverts {
    my ($c, $rpc_response, $req_storage) = @_;

    my $args     = $req_storage->{args};
    my $msg_type = $req_storage->{msg_type};

    if ($rpc_response->{error}) {
        return $c->new_error($msg_type, $rpc_response->{error}{code}, $rpc_response->{error}{message_to_client});
    }
    
    my $account_id = delete $rpc_response->{advertiser_account_id};
    my $advertiser_id = delete $rpc_response->{advertiser_id};

    my $result = {
        msg_type  => $msg_type,
        $msg_type => $rpc_response,
        defined $args->{req_id} ? (req_id => $args->{req_id}) : (),
    };

    return $result unless $args->{subscribe} and $c->stash('loginid');
    my $advert_id = $args->{id};

    my $sub = Binary::WebSocketAPI::v3::Subscription::P2P::Advert->new(
        c             => $c,
        args          => $args,
        loginid       => $c->stash('loginid'),
        account_id    => $account_id,
        advert_id     => $advert_id,
        advertiser_id => $advertiser_id,
    );

    if ($sub->already_registered) {
        my $msg =
              $advert_id
            ? $c->l('You are already subscribed to P2P Advert Info for advert [_1].', $advert_id)
            : $c->l('You are already subscribed to all adverts.');
        return $c->new_error($msg_type, 'AlreadySubscribed', $msg);
    }

    $sub->register;
    $sub->subscribe;
    $result->{subscription}{id} = $sub->uuid;
    return $result;

}

1;
