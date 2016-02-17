package BOM::WebSocketAPI::v3::Wrapper::Transaction;

use strict;
use warnings;

use JSON;
use List::Util qw(first);

use BOM::WebSocketAPI::Websocket_v3;
use BOM::WebSocketAPI::v3::Wrapper::System;
use BOM::WebSocketAPI::v3::Wrapper::Streamer;

sub buy {
    my ($c, $args) = @_;

    # calling forget_buy_proposal instead of forget_one as we need args for contract proposal
    my $contract_parameters = BOM::WebSocketAPI::v3::Wrapper::System::forget_buy_proposal($c, $args->{buy})
        or return $c->new_error('buy', 'InvalidContractProposal', $c->l("Unknown contract proposal"));

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c, 'buy',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('buy', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type => 'buy',
                    buy      => $response,
                };
            }
        },
        {
            args                => $args,
            client_loginid      => $c->stash('loginid'),
            token               => $c->stash('token'),
            source              => $c->stash('source'),
            contract_parameters => $contract_parameters
        });

    return;
}

sub sell {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c, 'sell',
        sub {
            my $response = shift;
            if (exists $response->{error}) {
                return $c->new_error('sell', $response->{error}->{code}, $response->{error}->{message_to_client});
            } else {
                return {
                    msg_type => 'sell',
                    sell     => $response,
                };
            }
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid'),
            token          => $c->stash('token'),
            source         => $c->stash('source')});
    return;
}

sub transaction {
    my ($c, $args) = @_;

    my $id;
    my $account_id = $c->stash('account_id');
    if ($account_id) {
        if (    exists $args->{subscribe}
            and $args->{subscribe} eq '1'
            and (not $id = BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'subscribe', $account_id, 'transaction', $args)))
        {
            return $c->new_error('transaction', 'AlreadySubscribed', $c->l('You are already subscribed to transaction updates.'));
        }
    }

    return {
        msg_type => 'transaction',
        transaction => {$id ? (id => $id) : ''}};
}

1;
