package BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement;

use strict;
use warnings;

use JSON;

use BOM::WebSocketAPI::CallingEngine;
use BOM::WebSocketAPI::v3::Wrapper::Streamer;
use BOM::WebSocketAPI::v3::Wrapper::System;

sub proposal_open_contract_make_call_params {
    my ($c, $args) = @_;
    return {contract_id => $args->{contract_id}};
}

sub proposal_open_contract_response_handler {
    my ($rpc_response, $api_response) = @_;
    my @contract_ids = keys %$rpc_response;
    if (scalar @contract_ids) {
        my $send_details = sub {
            my $response = shift;
            $c->send({
                    json => {
                        %$api_response,
                        echo_req => $args,
                        (exists $args->{req_id}) ? (req_id => $args->{req_id}) : (),
                        proposal_open_contract => {%$response}}});
        };
        foreach my $contract_id (@contract_ids) {
            if (exists $rpc_response->{$contract_id}->{error}) {
                $send_details->({
                        contract_id      => $contract_id,
                        validation_error => $rpc_response->{$contract_id}->{error}->{message_to_client}});
            } else {
                # need to do this as args are passed back to client as response echo_req
                my $details = {%$args};
                # we don't want to leak account_id to client
                $details->{account_id} = delete $rpc_response->{$contract_id}->{account_id};
                my $id;
                if (    exists $args->{subscribe}
                    and $args->{subscribe} eq '1'
                    and not $rpc_response->{$contract_id}->{is_expired}
                    and not $rpc_response->{$contract_id}->{is_sold})
                {
                    # these keys needs to be deleted from args (check send_proposal)
                    # populating here cos we stash them in redis channel
                    $details->{short_code}      = $rpc_response->{$contract_id}->{shortcode};
                    $details->{contract_id}     = $contract_id;
                    $details->{currency}        = $rpc_response->{$contract_id}->{currency};
                    $details->{buy_price}       = $rpc_response->{$contract_id}->{buy_price};
                    $details->{sell_price}      = $rpc_response->{$contract_id}->{sell_price};
                    $details->{sell_time}       = $rpc_response->{$contract_id}->{sell_time};
                    $details->{purchase_time}   = $rpc_response->{$contract_id}->{purchase_time};
                    $details->{is_sold}         = $rpc_response->{$contract_id}->{is_sold};
                    $details->{transaction_ids} = $rpc_response->{$contract_id}->{transaction_ids};

                    # need underlying to cancel streaming when manual sell occurs
                    $details->{underlying} = $rpc_response->{$contract_id}->{underlying};

                    # subscribe to transaction channel as when contract is manually sold we need to cancel streaming
                    BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'subscribe', $details->{account_id}, $contract_id, $details);

                    $id = BOM::WebSocketAPI::v3::Wrapper::Streamer::_feed_channel(
                        $c, 'subscribe',
                        $rpc_response->{$contract_id}->{underlying},
                        'proposal_open_contract:' . JSON::to_json($details), $details
                    );

                }
                my $res = {$id ? (id => $id) : (), %{$rpc_response->{$contract_id}}};
                $send_details->($res);
            }
        }
        return;
    } else {
        $api_response->{proposal_open_contract} = {};
        return $api_response;
    }
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
    my $short_code      = delete $details->{short_code};
    my $currency        = delete $details->{currency};
    my $is_sold         = delete $details->{is_sold};

    delete $details->{underlying};

    BOM::WebSocketAPI::CallingEngine::forward(
        $c,
        'get_bid',
        $details,
        {
            msg_type     => 'proposal_open_contract',
            stash_params => [qw/ token /],
            call_params  => sub {
                my ($c, $args) = @_;
                return {
                    short_code  => $short_code,
                    contract_id => $contract_id,
                    currency    => $currency,
                    is_sold     => $is_sold,
                    sell_time   => $sell_time,
                };
            },
            error => sub {
                my ($c, $args, $rpc_response) = @_;
                BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id) if $id;
                BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'unsubscribe', $account_id, $contract_id);
            },
            response => sub {
                my ($rpc_response, $api_response) = @_;
                if ($rpc_response) {
                    if (exists $rpc_response->{error}) {
                        return $api_response;
                    } elsif (exists $rpc_response->{is_expired} and $rpc_response->{is_expired} eq '1') {
                        BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id) if $id;
                        BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'unsubscribe', $account_id, $contract_id);
                        $id = undef;
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
                            %$rpc_response
                        }};
                } else {
                    BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id) if $id;
                    BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'unsubscribe', $account_id, $contract_id);
                }
            }
        });
    return;
}

1;
