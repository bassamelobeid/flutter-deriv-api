package BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement;

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);

use BOM::WebSocketAPI::v3::Wrapper::Streamer;
use BOM::WebSocketAPI::v3::Wrapper::System;

sub proposal_open_contract {
    my ($c, $response, $req_storage) = @_;

    my $args = $req_storage->{args};
    if (exists $response->{error}) {
        return $c->new_error('proposal_open_contract', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        my @contract_ids = keys %$response;
        if (scalar @contract_ids) {
            my $send_details = sub {
                my $result = shift;
                $c->send({
                        json => {
                            msg_type               => 'proposal_open_contract',
                            proposal_open_contract => {%$result}}
                    },
                    $req_storage
                );
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

                        # need to pass back original echo_req - with or without contract_id
                        $details->{echo_req} = $args;

                        # we don't want to leak account_id to client
                        $details->{account_id} = delete $response->{$contract_id}->{account_id};

                        # these keys needs to be deleted from args (check send_proposal_open_contract)
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
                        # req_id will be used separately for subscription, check feed subscribe
                        my %type_args = map { $_ =~ /req_id|passthrough/ ? () : ($_ => $args->{$_}) } keys %$args;

                        # pass account_id, transaction_id so that we can categorize it based on type, can't use contract_id
                        # as we send contract_id also, we want both request to stream i.e one with contract_id
                        # and one for all contracts
                        $type_args{account_id}     = $details->{account_id};
                        $type_args{transaction_id} = $response->{$contract_id}->{transaction_ids}->{buy};

                        my $keystr = join("", map { $_ . ":" . $type_args{$_} } sort keys %type_args);

                        $id = BOM::WebSocketAPI::v3::Wrapper::Streamer::_feed_channel_subscribe(
                            $c,
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

sub send_proposal_open_contract {
    my ($c, $id, $args) = @_;

    $c->call_rpc({
            args        => $args->{echo_req},
            method      => 'get_bid',
            msg_type    => 'proposal_open_contract',
            call_params => {
                short_code  => $args->{short_code},
                contract_id => $args->{contract_id},
                currency    => $args->{currency},
                is_sold     => $args->{is_sold},
                sell_time   => $args->{sell_time},
            },
            error => sub {
                my ($c, $rpc_response, $req_storage) = @_;
                BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id) if $id;
                return;
            },
            success => sub {
                my ($c, $rpc_response, $req_storage) = @_;
                if (exists $rpc_response->{is_expired} and $rpc_response->{is_expired} eq '1' and not $rpc_response->{is_valid_to_sell}) {
                    if ($id) {
                        warn "Unexpected proposal_open_contract message for account_id: " . $args->{account_id} . ",  id: $id";
                        BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id);
                        $id = undef;
                    }
                }
                return;
            },
            response => sub {
                my ($rpc_response, $api_response, $req_storage) = @_;

                return $api_response if $rpc_response->{error};

                $api_response->{proposal_open_contract}->{id}              = $id if $id;
                $api_response->{proposal_open_contract}->{buy_price}       = $args->{buy_price};
                $api_response->{proposal_open_contract}->{purchase_time}   = $args->{purchase_time};
                $api_response->{proposal_open_contract}->{transaction_ids} = $args->{transaction_ids};
                $api_response->{proposal_open_contract}->{sell_price}      = $args->{sell_price} if $args->{sell_price};
                $api_response->{proposal_open_contract}->{sell_time}       = $args->{sell_time} if $args->{sell_time};

                return $api_response;
            },
        });
    return;
}

1;
