package Binary::WebSocketAPI::v3::Wrapper::Accounts;

use 5.014;
use strict;
use warnings;

use List::Util qw(first);

use Binary::WebSocketAPI::v3::Wrapper::Transaction;
use Binary::WebSocketAPI::v3::Subscription;
use Binary::WebSocketAPI::v3::Subscription::BalanceAll;
use Binary::WebSocketAPI::v3::Subscription::Transaction;

sub set_self_exclusion_response_handler {
    my ($rpc_response, $api_response) = @_;
    if (exists $rpc_response->{error}) {
        $api_response->{error}->{field} = $rpc_response->{error}->{details} if (exists $rpc_response->{error}->{details});
    }
    return $api_response;
}

sub before_forward_balance {
    my ($c, $req_storage) = @_;

    my $args = $req_storage->{args};

    # check the case that the loginid not same with the requested account id
    my $arg_account = $args->{account} // 'current';
    my $loginid     = $c->stash('loginid');
    my $type        = 'balance';
    if ($arg_account eq 'all') {
        $type = 'balance_all';
    } elsif ($arg_account ne 'current') {
        $loginid = $arg_account;
    }

    # balance_all or not current loginid need oauth_token
    if ($c->stash('token_type') ne 'oauth_token') {
        if ($type eq 'balance_all') {
            return $c->new_error('balance', 'PermissionDenied', $c->l('Permission denied, balances of all accounts require oauth token'));
        } elsif ($type eq 'balance' && $loginid ne $c->stash('loginid')) {
            return $c->new_error('balance', 'PermissionDenied', $c->l('Permission denied, balance of other account requires oauth token'));
        }
    }

    my $already_registered;
    if ($type eq 'balance_all') {
        $already_registered = Binary::WebSocketAPI::v3::Subscription::BalanceAll->new(
            c    => $c,
            args => $args,
        )->already_registered;

    } elsif ($loginid eq $c->stash('loginid')) {
        $already_registered = Binary::WebSocketAPI::v3::Subscription::Transaction->new(
            c          => $c,
            account_id => $c->stash('account_id'),
            loginid    => $c->stash('loginid'),
            currency   => $c->stash('currency'),
            type       => 'balance',
            args       => $args,
        )->already_registered;
    }
    # else we will check again after bom-rpc response was got

    if (    exists $args->{subscribe}
        and $args->{subscribe}
        and $already_registered)
    {
        return $c->new_error('balance', 'AlreadySubscribed', $c->l('You are already subscribed to [_1] balance.', $arg_account));
    }
    return undef;
}

sub subscribe_transaction_channel {
    my ($c, $req_storage, $rpc_response) = @_;
    my $args = $req_storage->{args};
    return undef unless exists $args->{subscribe} and $args->{subscribe};
    unless ($rpc_response->result->{all}) {
        my $result     = $rpc_response->result;
        my $account_id = delete $result->{account_id};
        return undef unless $account_id;
        my $subscription = Binary::WebSocketAPI::v3::Subscription::Transaction->new(
            c          => $c,
            account_id => $account_id,
            loginid    => $result->{loginid},
            currency   => $result->{currency},
            type       => 'balance',
            args       => $args,
        );
        return $c->new_error('balance', 'AlreadySubscribed', $c->l('You are already subscribed to [_1] balance.', $result->{loginid}))
            if $subscription->already_registered;
        $subscription->register;
        $subscription->subscribe;
        $req_storage->{transaction_channel_id} = $subscription->uuid;
        return undef;
    }
    # now processing 'all'
    my $results = $rpc_response->result->{all};
    # First register a Transaction object to mark it as 'subscribed'
    my $balance_all = Binary::WebSocketAPI::v3::Subscription::BalanceAll->new(
        c              => $c,
        args           => $args,
        total_currency => $results->[0]{total}{real}{currency},
        total_balance  => $results->[0]{total}{real}{amount},
    );
    $balance_all->register;
    $req_storage->{transaction_channel_id} = $balance_all->uuid;
    for my $r (@$results) {
        my $account_id = delete $r->{account_id};
        unless ($account_id) {
            $r->{id} = '';
            next;
        }

        my $subscription = Binary::WebSocketAPI::v3::Subscription::Transaction->new(
            c                               => $c,
            account_id                      => $account_id,
            loginid                         => $r->{loginid},
            currency                        => $r->{currency},
            type                            => 'balance',
            args                            => $args,
            currency_rate_in_total_currency => $r->{currency_rate_in_total_currency},
            balance_all_proxy               => $balance_all,
        );
        my $id = $subscription->already_registered ? '' : $subscription->uuid;

        $r->{id} = $balance_all->uuid;
        if ($id) {
            $balance_all->add_subscription($subscription);
        } else {
            # TODO else we can set balance_all_proxy here
            $r->{error} = $c->new_error('balance', 'AlreadySubscribed', $c->l('You are already subscribed to [_1].', 'balance'));
        }
    }
    return undef;
}

sub balance_error_handler {
    my ($c, undef, $req_storage) = @_;
    Binary::WebSocketAPI::v3::Subscription->unregister_by_uuid($c, $req_storage->{transaction_channel_id})
        if $req_storage->{transaction_channel_id};
    return;
}

sub balance_success_handler {
    my ($c, $rpc_response, $req_storage) = @_;
    my @results;
    if ($rpc_response->{all}) {
        @results = @{delete $rpc_response->{all}};
    } else {
        @results = $rpc_response;
    }
    map {
        delete $_->{currency_rate_in_total_currency};
        delete $_->{account_id};
        $_->{id} = $req_storage->{transaction_channel_id} if $req_storage->{transaction_channel_id};
    } @results;

    #send from 0 to -1, the last one will be sent by $rpc_response;
    %$rpc_response = (%{pop @results});
    for my $r (@results) {
        my $api_response = {
            balance  => $r,
            msg_type => 'balance',
            echo_req => $req_storage->{args}};
        balance_response_handler($rpc_response, $api_response, $req_storage);
        $c->send({json => $api_response});
    }
    return;
}

=head2 balance_response_handler

An event handler invoked by websocket API before sending B<balance> response.
Currently it is used for adding a subscription attribute to the JSON.

=cut

sub balance_response_handler {
    my ($rpc_response, $api_response, $req_storage) = @_;

    $api_response->{passthrough} = $req_storage->{args}->{passthrough};
    return $api_response if $rpc_response->{error};
    if (my $uuid = $rpc_response->{id}) {
        $api_response->{subscription}->{id} = $uuid;
    }
    return $api_response;
}

sub login_history_response_handler {
    my ($rpc_response, $api_response) = @_;
    $api_response->{login_history} = $rpc_response->{records} if not exists $rpc_response->{error};
    return $api_response;
}

sub set_account_currency_params_handler {
    my (undef, $req_storage) = @_;
    $req_storage->{call_params}->{currency} = $req_storage->{args}->{set_account_currency};
    return;
}

1;
