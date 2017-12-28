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

sub subscribe_transaction_channel {
    my ($c, $req_storage) = @_;

    my $id;
    my $args       = $req_storage->{args};
    my $account_id = $c->stash('account_id');
    if (    $account_id
        and exists $args->{subscribe}
        and $args->{subscribe} eq '1'
        and (not $id = Binary::WebSocketAPI::v3::Wrapper::Streamer::transaction_channel($c, 'subscribe', $account_id, 'balance', $args)))
    {
        return $c->new_error('balance', 'AlreadySubscribed', $c->l('You are already subscribed to balance updates.'));
    }

    $req_storage->{transaction_channel_id} = $id if $id;
    return;
}

sub balance_error_handler {
    my ($c, undef, $req_storage) = @_;
    Binary::WebSocketAPI::v3::Wrapper::System::forget_one($c, $req_storage->{transaction_channel_id}) if $req_storage->{transaction_channel_id};
    return;
}

sub balance_success_handler {
    my (undef, $rpc_response, $req_storage) = @_;
    $rpc_response->{id} = $req_storage->{transaction_channel_id} if $req_storage->{transaction_channel_id};
    return;
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
