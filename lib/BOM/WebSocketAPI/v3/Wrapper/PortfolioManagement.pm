package BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement;

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);

use BOM::WebSocketAPI::Websocket_v3;
use BOM::WebSocketAPI::v3::Wrapper::Streamer;
use BOM::WebSocketAPI::v3::Wrapper::System;

sub proposal_open_contract {
    my ($c, $args, $response) = @_;

    if (exists $response->{error}) {
        return $c->new_error('proposal_open_contract', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        my @contract_ids = keys %$response;
        if (scalar @contract_ids) {
            my $send_details = sub {
                my $result = shift;
                $c->send({
                        json => {
                            echo_req => $args,
                            (exists $args->{req_id}) ? (req_id => $args->{req_id}) : (),
                            msg_type               => 'proposal_open_contract',
                            proposal_open_contract => {%$result}}});
            };
            foreach my $contract_id (@contract_ids) {
                if (exists $response->{$contract_id}->{error}) {
                    $send_details->({
                            contract_id      => $contract_id,
                            validation_error => $response->{$contract_id}->{error}->{message_to_client}});
                } else {
                    my $id;
                    if (    exists $args->{subscribe}
                        and $args->{subscribe} eq '1'
                        and not $response->{$contract_id}->{is_expired}
                        and not $response->{$contract_id}->{is_sold})
                    {
                        # need to do this as args are passed back to client as response echo_req
                        my $details = {%$args};

                        # we don't want to leak account_id to client
                        $details->{account_id} = delete $response->{$contract_id}->{account_id};

                        # these keys needs to be deleted from args (check send_proposal)
                        # populating here cos we stash them in redis channel
                        $details->{short_code}      = $response->{$contract_id}->{shortcode};
                        $details->{contract_id}     = $contract_id;
                        $details->{currency}        = $response->{$contract_id}->{currency};
                        $details->{buy_price}       = $response->{$contract_id}->{buy_price};
                        $details->{sell_price}      = $response->{$contract_id}->{sell_price};
                        $details->{sell_time}       = $response->{$contract_id}->{sell_time};
                        $details->{purchase_time}   = $response->{$contract_id}->{purchase_time};
                        $details->{is_sold}         = $response->{$contract_id}->{is_sold};
                        $details->{transaction_ids} = $response->{$contract_id}->{transaction_ids};

                        # as req_id and passthrough can change so we should not send them in type else
                        # client can subscribe to multiple proposal_open_contract as feed channel type will change
                        my %type_args = map { $_ =~ /req_id|passthrough/ ? () : ($_ => $args->{$_}) } keys %$args;

                        # pass account_id, transaction_id so that we can categorize it based on type, can't use contract_id
                        # as we send contract_id also, we want both request to stream i.e one with contract_id
                        # and one for all contracts
                        $type_args{account_id}     = $details->{account_id};
                        $type_args{transaction_id} = $response->{$contract_id}->{transaction_ids}->{buy};

                        my $keystr = join("", map { $_ . ":" . $type_args{$_} } sort keys %type_args);

                        $id = BOM::WebSocketAPI::v3::Wrapper::Streamer::_feed_channel(
                            $c, 'subscribe',
                            $response->{$contract_id}->{underlying},
                            'proposal_open_contract:' . md5_hex($keystr), $details
                        );

                        # subscribe to transaction channel as when contract is manually sold we need to cancel streaming
                        BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'subscribe', $details->{account_id}, $id, $details) if $id;
                    }
                    my $res = {$id ? (id => $id) : (), %{$response->{$contract_id}}};
                    $send_details->($res);
                }
            }
            return;
        } else {
            return {
                msg_type               => 'proposal_open_contract',
                proposal_open_contract => {}};
        }
    }
    return;
}

sub send_proposal {
    my ($c, $id, $args) = @_;

    my $details         = {%$args};
    my $contract_id     = delete $details->{contract_id};
    my $sell_time       = delete $details->{sell_time};
    my $account_id      = delete $details->{account_id};
    my $buy_price       = delete $details->{buy_price};
    my $purchase_time   = delete $details->{purchase_time};
    my $sell_price      = delete $details->{sell_price};
    my $transaction_ids = delete $details->{transaction_ids};

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'get_bid',
        sub {
            my $response = shift;
            if ($response) {
                if (exists $response->{error}) {
                    if ($id) {
                        BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id);
                        BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'unsubscribe', $account_id, $id);
                    }
                    return $c->new_error('proposal_open_contract', $response->{error}->{code}, $response->{error}->{message_to_client});
                } elsif (exists $response->{is_expired} and $response->{is_expired} eq '1') {
                    if ($id) {
                        BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id);
                        BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'unsubscribe', $account_id, $id);
                        $id = undef;
                    }
                }

                return {
                    msg_type               => 'proposal_open_contract',
                    proposal_open_contract => {
                        $id ? (id => $id) : (),
                        buy_price       => $buy_price,
                        purchase_time   => $purchase_time,
                        transaction_ids => $transaction_ids,
                        (defined $sell_price) ? (sell_price => sprintf('%.2f', $sell_price)) : (),
                        (defined $sell_time) ? (sell_time => $sell_time) : (),
                        %$response
                    }};
            } else {
                if ($id) {
                    BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id);
                    BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'unsubscribe', $account_id, $id);
                }
            }
        },
        {
            short_code            => delete $details->{short_code},
            contract_id           => $contract_id,
            currency              => delete $details->{currency},
            is_sold               => delete $details->{is_sold},
            sell_time             => $sell_time,
            app_markup_percentage => $c->stash('app_markup_percentage') // 0,
            args                  => $details
        },
        'proposal_open_contract'
    );
    return;
}

1;
