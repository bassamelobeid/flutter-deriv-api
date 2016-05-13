package BOM::WebSocketAPI::v3::Wrapper::Accounts;

use 5.014;
use strict;
use warnings;

use JSON;
use List::Util qw(first);

use BOM::WebSocketAPI::Websocket_v3;
use BOM::WebSocketAPI::v3::Wrapper::Streamer;

sub set_self_exclusion_response_handler {
    my ($rpc_response, $api_response) = @_;
    if (exists $rpc_response->{error}) {
        $api_response->{error}->{field} = $rpc_response->{error}->{details} if (exists $rpc_response->{error}->{details});
    }
    return $api_response;
}

sub balance {
    my ($c, $args) = @_;

    my $id;
    my $account_id = $c->stash('account_id');
    if (    $account_id
        and exists $args->{subscribe}
        and $args->{subscribe} eq '1'
        and (not $id = BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'subscribe', $account_id, 'balance', $args)))
    {
        return $c->new_error('balance', 'AlreadySubscribed', $c->l('You are already subscribed to balance updates.'));
    }

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'balance',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id) if $id;
                return $c->new_error('balance', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type => 'balance',
                    balance => {$id ? (id => $id) : (), %$response}};
            }
        },
        {
            args  => $args,
            token => $c->stash('token'),
        });
    return;
}

sub login_history_response_handler {
    my ($rpc_response, $api_response) = @_;
    $api_response->{login_history} = $rpc_response->{records} if not exists $rpc_response->{error};
    return $api_response;
}

sub set_account_currency_params_handler {
    my ($c, $args) = @_;
    return {currency => $args->{set_account_currency}};
}

1;
