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

=head2 balance_response_handler

Called on successful RPC response.
Creates subscriptions and cleans up fields.
Subscription errors will be set in $rpc_response to be handled in balance_response_handler().

=cut

sub balance_success_handler {
    my ($c, $rpc_response, $req_storage) = @_;

    my $args       = $req_storage->{args};
    my $account_id = delete $rpc_response->{account_id};

    if ($args->{subscribe} and ($args->{account} // '') ne 'all') {

        unless ($account_id) {
            $rpc_response->{subscribe_error} =
                $c->new_error('balance', 'NoAccountCurrency', $c->l('You cannot subscribe to an account with no currency selected.'));
            return;
        }

        my $subscription = Binary::WebSocketAPI::v3::Subscription::Transaction->new(
            c          => $c,
            account_id => $account_id,
            loginid    => $rpc_response->{loginid},
            currency   => $rpc_response->{currency},
            type       => 'balance',
            args       => $args,
        );

        if ($subscription->already_registered) {
            $rpc_response->{subscribe_error} =
                $c->new_error('balance', 'AlreadySubscribed',
                $c->l('You are already subscribed to balance for account [_1].', $rpc_response->{loginid}));
            return;
        }

        $subscription->register;
        $subscription->subscribe;
        $rpc_response->{id} = $subscription->uuid;
    }

    my $balance_all;
    if ($args->{subscribe} and ($args->{account} // '') eq 'all') {

        $balance_all = Binary::WebSocketAPI::v3::Subscription::BalanceAll->new(
            c              => $c,
            args           => $args,
            total_currency => $rpc_response->{total}{deriv}{currency},
            total_balance  => $rpc_response->{total}{deriv}{amount},
        );

        if ($balance_all->already_registered) {
            $rpc_response->{subscribe_error} =
                $c->new_error('balance', 'AlreadySubscribed', $c->l('You are already subscribed to balance for all accounts.'));
            return;
        }

        $balance_all->register;
        $rpc_response->{id} = $balance_all->uuid;
    }

    if ($rpc_response->{accounts}) {
        for my $loginid (keys $rpc_response->{accounts}->%*) {
            my $account = $rpc_response->{accounts}{$loginid};

            my $total_rate = delete $account->{currency_rate_in_total_currency};
            my $account_id = delete $account->{account_id};
            next unless $account_id;

            if ($balance_all and $account->{type} eq 'deriv') {
                my $subscription = Binary::WebSocketAPI::v3::Subscription::Transaction->new(
                    c                               => $c,
                    account_id                      => $account_id,
                    loginid                         => $loginid,
                    currency                        => $account->{currency},
                    type                            => 'balance',
                    args                            => $args,
                    currency_rate_in_total_currency => $total_rate,
                    balance_all_proxy               => $balance_all,
                );

                $balance_all->add_subscription($subscription);
            }
        }
    }
    return;
}

=head2 balance_response_handler

An event handler invoked by websocket API before sending B<balance> response.
Used to add subscription id and return subscription errors.

=cut

sub balance_response_handler {
    my ($rpc_response, $api_response) = @_;

    return $api_response if $api_response->{error};
    return $rpc_response->{subscribe_error} if $rpc_response->{subscribe_error};
    # subscription id is duplicated for backwards compatibility reasons
    if (my $uuid = $api_response->{balance}{id}) {
        $api_response->{subscription}{id} = $uuid;
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
