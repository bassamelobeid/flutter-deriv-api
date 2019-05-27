package Binary::WebSocketAPI::v3::Wrapper::Accounts;

use 5.014;
use strict;
use warnings;

use List::Util qw(first);

use Binary::WebSocketAPI::v3::Wrapper::Streamer;

sub set_self_exclusion_response_handler {
    my ($rpc_response, $api_response) = @_;
    if (exists $rpc_response->{error}) {
        $api_response->{error}->{field} = $rpc_response->{error}->{details} if (exists $rpc_response->{error}->{details});
    }
    return $api_response;
}

sub before_forward_balance {
    my ($c, $req_storage) = @_;

    my $args    = $req_storage->{args};
    my $channel = $c->stash('transaction_channel');

    my $already_subscribed = $channel ? exists $channel->{balance} : 0;

    if (    exists $args->{subscribe}
        and $args->{subscribe}
        and $already_subscribed)
    {
        return $c->new_error('balance', 'AlreadySubscribed', $c->l('You are already subscribed to balance updates.'));
    }
    return undef;
}

sub subscribe_transaction_channel {
    my ($c, $req_storage) = @_;

    my $args = $req_storage->{args};

    return undef unless exists $args->{subscribe} and $args->{subscribe};
    my $account_id = $c->stash('account_id');
    my $id = Binary::WebSocketAPI::v3::Wrapper::Streamer::transaction_channel($c, 'subscribe', $account_id, 'balance', $args);

    $req_storage->{transaction_channel_id} = $id if $id;
    return undef;
}

sub balance_error_handler {
    my ($c, undef, $req_storage) = @_;
    Binary::WebSocketAPI::v3::Wrapper::System::forget_one($c, $req_storage->{transaction_channel_id}) if $req_storage->{transaction_channel_id};
    return;
}

sub balance_success_handler {
    my ($c, $rpc_response, $req_storage) = @_;
    $rpc_response->{id} = $req_storage->{transaction_channel_id} if $req_storage->{transaction_channel_id};
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
