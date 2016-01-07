package BOM::WebSocketAPI::v3::Wrapper::Transaction;

use strict;
use warnings;

use BOM::RPC::v3::Transaction;
use BOM::WebSocketAPI::v3::Wrapper::System;

sub buy {
    my ($c, $args) = @_;

    my $contract_parameters = BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $args->{buy})
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

    my $client = $c->stash('client');
    if ($client) {
        my $redis              = $c->stash('redis');
        my $channel            = 'TXNUPDATE::transaction_' . $client->default_account->id;
        my $subscriptions      = $c->stash('transaction_channel') // {};
        my $already_subscribed = $subscriptions->{$channel};

        if (exists $args->{subscribe} and $args->{subscribe} eq '1') {
            if (!$already_subscribed) {
                $redis->subscribe([$channel], sub { });
                $subscriptions->{$channel} = 1;
                $subscriptions->{args} = $args;
                $c->stash('transaction_channel', $subscriptions);
            }
        }
        if (exists $args->{subscribe} and $args->{subscribe} eq '0') {
            if ($already_subscribed) {
                $redis->unsubscribe([$channel], sub { });
                delete $subscriptions->{$channel};
                delete $subscriptions->{args};
                delete $c->stash->{transaction_channel};
            }
        }
    }
    return;
}

sub send_transaction_updates {
    my ($c, $message) = @_;

    my $args = {};
    my $channel;
    my $client        = $c->stash('client');
    my $subscriptions = $c->stash('transaction_channel');
    if ($subscriptions) {
        $channel = $subscriptions->{(first { m/TXNUPDATE::transaction/ } keys %$subscriptions) || ''};
        $args = exists $subscriptions->{args} ? $subscriptions->{args} : {};
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
                        transaction_id => $payload->{id}}}}) if $c->tx;
    } else {
        if ($channel) {
            $c->stash('redis')->unsubscribe([$channel], sub { });
            delete $c->stash->{transaction_channel};
        }
    }
    return;
}

1;
