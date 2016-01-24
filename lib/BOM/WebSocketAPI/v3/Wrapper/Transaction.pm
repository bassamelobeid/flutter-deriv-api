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
    my $account_id = $c->stash('account_id');
    if ($account_id) {
        my $redis              = $c->stash('redis');
        my $channel            = 'TXNUPDATE::transaction_' . $account_id;
        my $subscriptions      = $c->stash('transaction_channel');
        my $already_subscribed = $subscriptions->{$channel};

        if (    exists $args->{subscribe}
            and $args->{subscribe} eq '1'
            and (not $id = BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'subscribe', $account_id, $args)))
        {
            return $c->new_error('transaction', 'AlreadySubscribed', $c->l('You are already subscribed to transaction updates.'));
        }
    }

    return {
        msg_type => 'transaction',
        transaction => {$id ? (id => $id) : ''}};
}

sub send_transaction_updates {
    my ($c, $message) = @_;

    my $args = {};
    my $channel;
    my $subscriptions = $c->stash('transaction_channel');
    if ($subscriptions) {
        $channel = first { m/TXNUPDATE::transaction/ } keys %$subscriptions;
        $args = ($channel and exists $subscriptions->{$channel}->{args}) ? $subscriptions->{$channel}->{args} : {};
    }

    if ($c->stash('account_id')) {
        my $payload = JSON::from_json($message);

        BOM::WebSocketAPI::Websocket_v3::rpc(
            $c,
            'get_contract_details',
            sub {
                my $response = shift;
                my $id = $subscriptions->{$channel}->{uuid} if ($channel and exists $subscriptions->{$channel}->{uuid});
                if (exists $response->{error}) {
                    BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id) if $id;
                    return $c->new_error('transaction', $response->{error}->{code}, $response->{error}->{message_to_client});
                } else {
                    my $txn_time;
                    if (exists $payload->{referrer_type} and $payload->{referrer_type} eq 'financial_market_bet') {
                        if ($payload->{action_type} eq 'sell') {
                            $txn_time = Date::Utility->new($txn->{sell_time})->epoch;
                        } else {
                            $txn_time = Date::Utility->new($txn->{purchase_time})->epoch;
                        }
                    } else {
                        $txn_time = Date::Utility->new($txn->{payment_time})->epoch;
                    }

                    $c->send({
                            json => {
                                msg_type => 'transaction',
                                $args ? (echo_req => $args) : (),
                                ($args and exists $args->{req_id}) ? (req_id => $args->{req_id}) : (),
                                transaction => {
                                    balance          => $payload->{balance_after},
                                    action           => $payload->{action_type},
                                    contract_id      => $payload->{financial_market_bet_id},
                                    amount           => $payload->{amount},
                                    transaction_id   => $payload->{id},
                                    transaction_time => $txn_time,
                                    ($payload->{action_type} eq 'sell') ? (purchase_time => Date::Utility->new($payload->{purchase_time})->epoch) : (),
                                    %$response,
                                    $id ? (id => $id) : ()}}});
                }
            },
            {
                args           => $args,
                client_loginid => $c->stash('loginid'),
                shortcode      => $payload->{short_code},
                currency       => $payload->{currency_code},
                language       => $c->stash('request')->language
            });
    } elsif ($channel and exists $subscriptions->{$channel}->{account_id}) {
        BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'unsubscribe', $subscriptions->{$channel}->{account_id}, $args);
    }
    return;
}

1;
