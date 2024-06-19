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
use Binary::WebSocketAPI::v3::Subscription::P2P::P2PSettings;
use Log::Any qw($log);

sub subscribe_orders {
    my ($c, $rpc_response, $req_storage) = @_;
    my $args     = $req_storage->{args};
    my $msg_type = $req_storage->{msg_type};

    if ($rpc_response->{error}) {
        return $c->new_error($msg_type, $rpc_response->{error}{code}, $rpc_response->{error}{message_to_client});
    }

    my $loginid = $c->stash('loginid');
    my $broker  = $c->stash('broker');

    if ($args->{loginid}) {
        $loginid = $args->{loginid};
        $broker  = $c->stash('account_tokens')->{$loginid}{broker};
    }

    my $subscription_info = delete $rpc_response->{subscription_info};    # needed for subscription, not part of response
    my $result            = {
        msg_type  => $msg_type,
        $msg_type => $rpc_response,
        defined $args->{req_id} ? (req_id => $args->{req_id}) : (),
    };

    return $result unless $args->{subscribe} and $loginid and $broker;

    my $order_id =
          $msg_type eq 'p2p_order_info'   ? $args->{id}
        : $msg_type eq 'p2p_order_create' ? $rpc_response->{id}
        :                                   undef;

    my $sub = Binary::WebSocketAPI::v3::Subscription::P2P::Order->new(
        c       => $c,
        args    => $args,
        loginid => $loginid,
        broker  => $broker,
        %$subscription_info
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

    my $advertiser_loginid = delete $rpc_response->{client_loginid};    # needed for subscription, not part of response

    my $loginid = $args->{loginid} // $c->stash('loginid');

    my $result = {
        msg_type  => $msg_type,
        $msg_type => $rpc_response,
        defined $args->{req_id} ? (req_id => $args->{req_id}) : (),
    };

    return $result unless $args->{subscribe} and $loginid and $advertiser_loginid;

    my $sub = Binary::WebSocketAPI::v3::Subscription::P2P::Advertiser->new(
        c                  => $c,
        args               => $args,
        loginid            => $loginid,
        advertiser_loginid => $advertiser_loginid,
    );

    if ($sub->already_registered) {
        return $c->new_error($msg_type, 'AlreadySubscribed', $c->l('You are already subscribed to this P2P advertiser.'));
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

    my $account_id    = delete $rpc_response->{advertiser_account_id};
    my $advertiser_id = delete $rpc_response->{advertiser_id};

    my $result = {
        msg_type  => $msg_type,
        $msg_type => $rpc_response,
        defined $args->{req_id} ? (req_id => $args->{req_id}) : (),
    };

    my $loginid = $args->{loginid} // $c->stash('loginid');

    return $result unless $args->{subscribe} and $loginid;
    my $advert_id = $args->{id};

    my $sub = Binary::WebSocketAPI::v3::Subscription::P2P::Advert->new(
        c             => $c,
        args          => $args,
        loginid       => $loginid,
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

=head2 subscribe_p2p_settings

Handle subscriptions for p2p_settings

=cut

sub subscribe_p2p_settings {
    my ($c, $rpc_response, $req_storage) = @_;
    my $args     = $req_storage->{args};
    my $msg_type = $req_storage->{msg_type};
    # checking rpc response for errors
    if ($rpc_response->{error}) {
        return $c->new_error($msg_type, $rpc_response->{error}{code}, $rpc_response->{error}{message_to_client});
    }

    my $result = {
        msg_type  => $msg_type,
        $msg_type => $rpc_response,
        defined $args->{req_id} ? (req_id => $args->{req_id}) : (),
    };

    # If no subscription required, just return result
    return $result unless $args->{subscribe};
    my $subscription_info = delete $rpc_response->{subscription_info};                       # needed for subscription, not part of response
    my $sub               = Binary::WebSocketAPI::v3::Subscription::P2P::P2PSettings->new(
        c    => $c,
        args => $args,
        %$subscription_info                                                                  #contains country code for channel creation
    );

    # check for double subscription
    if ($sub->already_registered) {
        return $c->new_error($msg_type, 'AlreadySubscribed', $c->l('You are already subscribed to P2P settings'));
    }

    $sub->register;
    $sub->subscribe;
    $result->{subscription}{id} = $sub->uuid;
    return $result;
}

1;
