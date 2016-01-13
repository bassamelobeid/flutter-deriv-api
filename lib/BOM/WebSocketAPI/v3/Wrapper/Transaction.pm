package BOM::WebSocketAPI::v3::Wrapper::Transaction;

use strict;
use warnings;

use JSON;
use List::Util qw(first);

use BOM::WebSocketAPI::Websocket_v3;
use BOM::WebSocketAPI::v3::Wrapper::System;

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
            source         => $c->stash('source')});
    return;
}

sub transaction {
    my ($c, $args) = @_;

    my $id;
    my $client = $c->stash('client');
    if ($client and $client->default_account) {
        my $redis              = $c->stash('redis');
        my $channel            = 'TXNUPDATE::transaction_' . $client->default_account->id;
        my $subscriptions      = $c->stash('transaction_channel');
        my $already_subscribed = $subscriptions->{$channel};

        if (    exists $args->{subscribe}
            and $args->{subscribe} eq '1'
            and (not $id = BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'subscribe', $client->default_account->id, $args)))
        {
            return $c->new_error('transaction', 'AlreadySubscribed', $c->l('You are already subscribed to transaction updates.'));
        }
    }

    $c->send({
            json => {
                echo_req => $args,
                ($args and exists $args->{req_id}) ? (req_id => $args->{req_id}) : (),
                msg_type => 'transaction',
                transaction => {$id ? (id => $id) : ''}}});
    return;
}

sub send_transaction_updates {
    my ($c, $message) = @_;

    my $args = {};
    my $channel;
    my $client        = $c->stash('client');
    my $subscriptions = $c->stash('transaction_channel');
    if ($subscriptions) {
        $channel = first { m/TXNUPDATE::transaction/ } keys %$subscriptions;
        $args = ($channel and exists $subscriptions->{$channel}->{args}) ? $subscriptions->{$channel}->{args} : {};
    }

    if ($client) {
        my $payload = JSON::from_json($message);
        $c->send({
                json => {
                    msg_type => 'transaction',
                    $args ? (echo_req => $args) : (),
                    ($args and exists $args->{req_id}) ? (req_id => $args->{req_id}) : (),
                    transaction => {
                        balance        => $payload->{balance_after},
                        action         => $payload->{action_type},
                        contract_id    => $payload->{financial_market_bet_id},
                        amount         => $payload->{amount},
                        transaction_id => $payload->{id},
                        ($channel and exists $subscriptions->{$channel}->{uuid}) ? (id => $subscriptions->{$channel}->{uuid}) : ()}}}) if $c->tx;
    } elsif ($channel and exists $subscriptions->{$channel}->{account_id}) {
        BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'unsubscribe', $subscriptions->{$channel}->{account_id}, $args);
    }
    return;
}

1;
