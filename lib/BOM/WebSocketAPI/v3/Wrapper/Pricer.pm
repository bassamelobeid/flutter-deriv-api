package BOM::WebSocketAPI::v3::Wrapper::Pricer;

use strict;
use warnings;
use JSON;
use Data::UUID;
use List::Util qw(first);
use Format::Util::Numbers qw(roundnear);
use BOM::RPC::v3::Contract;
use BOM::WebSocketAPI::v3::Wrapper::System;
use Mojo::Redis::Processor;
use JSON::XS qw(encode_json decode_json);
use BOM::System::RedisReplicated;
use Time::HiRes qw(gettimeofday);
use BOM::WebSocketAPI::v3::Wrapper::Streamer;
use Data::Dumper;
use BOM::Platform::Client;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;

sub proposal {
    my ($c, $req_storage) = @_;

    my $symbol   = $req_storage->{args}->{symbol};
    my $response = BOM::RPC::v3::Contract::validate_symbol($symbol);
    if ($response and exists $response->{error}) {
        return $c->new_error('proposal', $response->{error}->{code}, $c->l($response->{error}->{message}, $symbol));
    } else {
        _send_ask($c, $req_storage);
    }
    return;
}

sub proposal_open_contract {
    my ($c, $req_storage) = @_;
    my $args = $req_storage->{args};

    $c->call_rpc({
            args            => $args,
            method          => 'proposal_open_contract',
            msg_type        => 'proposal_open_contract',
            rpc_response_cb => \&proposal_open_contract_cb,
            require_auth    => 'read',
            stash_params    => [qw( language country_code source token )],
        });
    return;
}

sub proposal_open_contract_cb {
    my ($c, $response, $req_storage) = @_;

    my $args = $req_storage->{args};
    #warn "POC_cb: args: ".Dumper($args);
    #warn "POC_CB: resp: ".Dumper($response);
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
                        my %type_args = map { $_ =~ /req_id|passthrough/ ? () : ($_ => $args->{$_}) } keys %$args;

                        # pass account_id, transaction_id so that we can categorize it based on type, can't use contract_id
                        # as we send contract_id also, we want both request to stream i.e one with contract_id
                        # and one for all contracts
                        $type_args{account_id}     = $details->{account_id};
                        $type_args{transaction_id} = $response->{$contract_id}->{transaction_ids}->{buy};

                        my $keystr = join("", map { $_ . ":" . $type_args{$_} } sort keys %type_args);
                        my $uuid = Data::UUID->new->create_str();

                        #warn "Detalis to construct args for subscripbin to pricing chan: ".Dumper($details);
                        my $subscribe_args = {
                            id          => $uuid,
                            short_code  => $details->{short_code},
                            contract_id => $details->{contract_id},
                            currency    => $details->{currency},
                            is_sold     => $details->{is_sold},
                            sell_time   => $details->{sell_time},
                            subscribe   => 1,
                            passthrough => $details->{passthrough},
                            transaction_ids => $response->{$contract_id}->{transaction_ids},
                            purchase_time => $details->{purchase_time},
                        };
                        my $c_uuid;
                        if (not $c_uuid = _pricing_channel($c, 'subscribe', $subscribe_args)) {
                            warn "Error - not subscribed!";
                            return $c->new_error('proposal_open_contract',
                                    'AlreadySubscribedOrLimit', $c->l('You are either already subscribed or you have reached the limit for proposal_open_contract subscription.'));
                        }

                        # subscribe to transaction channel as when contract is manually sold we need to cancel streaming
                        #warn "Passing to subst to transaction id $uuid\n";
                        BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'subscribe', $details->{account_id}, $uuid, $details); # if $id;
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

sub _send_ask {
    my ($c, $req_storage, $api_name) = @_;
    my $args = $req_storage->{args};

    $c->call_rpc({
            args            => $args,
            method          => 'send_ask',
            msg_type        => 'proposal',
            rpc_response_cb => sub {
                my ($c, $rpc_response, $req_storage) = @_;
                my $args = $req_storage->{args};

                if ($rpc_response and exists $rpc_response->{error}) {
                    my $err = $c->new_error('proposal', $rpc_response->{error}->{code}, $rpc_response->{error}->{message_to_client});
                    $err->{error}->{details} = $rpc_response->{error}->{details} if (exists $rpc_response->{error}->{details});
                    return $err;
                }

                my $uuid;

                if (not $uuid = _pricing_channel($c, 'subscribe', $args)) {
                    return $c->new_error('proposal',
                        'AlreadySubscribedOrLimit',
                        $c->l('You are either already subscribed or you have reached the limit for proposal subscription.'));
                }

                # if uuid is set (means subscribe:1), and channel stil exists we cache the longcode here (reposnse from rpc) to add them to responses from pricer_daemon.
                my $pricing_channel = $c->stash('pricing_channel');
                if ($uuid and exists $pricing_channel->{uuid}->{$uuid}) {
                    my $serialized_args = $pricing_channel->{uuid}->{$uuid}->{serialized_args};
                    my $amount = $args->{amount_per_point} || $args->{amount};
                    $pricing_channel->{$serialized_args}->{$amount}->{longcode} = $rpc_response->{longcode};
                    $c->stash('pricing_channel' => $pricing_channel);
                }

                return {
                    msg_type   => 'proposal',
                    'proposal' => {($uuid ? (id => $uuid) : ()), %$rpc_response}};
            }
        });
    return;
}

sub _serialized_args {
    my $h = shift;
    my @a = ();
    foreach my $k (sort keys %$h) {
        push @a, ($k, $h->{$k});
    }
    return 'PRICER_KEYS::' . encode_json(\@a);
}

sub _pricing_channel {
    my ($c, $subs, $args) = @_;

    my %args_hash = %{$args};

    if ($args_hash{basis}) {
        $args_hash{amount} = 1000;
        $args_hash{basis}  = 'payout';
    }

    $args_hash{dispatch_to} = $args_hash{passthrough}{dispatch_to};
    delete $args_hash{passthrough};
    delete $args_hash{req_id};

    $args_hash{language} = $c->stash('language') || 'EN';
    my $serialized_args = _serialized_args(\%args_hash);

    my $pricing_channel = $c->stash('pricing_channel') || {};

    my $amount = $args->{amount_per_point} || $args->{amount};
    $amount //= 0;

    if ($pricing_channel->{$serialized_args} and $pricing_channel->{$serialized_args}->{$amount}) {
        return;
    }

    my $uuid = $args->{id} || Data::UUID->new->create_str();

    # subscribe if it is not already subscribed
    if (    not $pricing_channel->{$serialized_args}
        and not BOM::WebSocketAPI::v3::Wrapper::Streamer::_skip_streaming($args)
        and $args->{subscribe}
        and $args->{subscribe} == 1)
    {
        warn "_pricing_channel : subs: $uuid\n";
        BOM::System::RedisReplicated::redis_pricer->set($serialized_args, 1);
        $c->stash('redis_pricer')->subscribe([$serialized_args], sub { });
    }

    $pricing_channel->{$serialized_args}->{$amount}->{uuid} = $uuid;
    $pricing_channel->{$serialized_args}->{$amount}->{args} = $args;
    $pricing_channel->{uuid}->{$uuid}->{serialized_args}    = $serialized_args;
    $pricing_channel->{uuid}->{$uuid}->{amount}             = $amount;
    $pricing_channel->{uuid}->{$uuid}->{args}               = $args;

    $c->stash('pricing_channel' => $pricing_channel);
    return $uuid;
}

sub process_pricing_events {
    my ($c, $message, $chan) = @_;

    # in case that it is a spread
    return if not $message or not $c->tx;
    $message =~ s/^PRICER_KEYS:://;

    my $response        = decode_json($message);
    my $serialized_args = $chan;

    my $pricing_channel = $c->stash('pricing_channel');
    return if not $pricing_channel or not $pricing_channel->{$serialized_args};

    foreach my $amount (keys %{$pricing_channel->{$serialized_args}}) {
        my $results;
        if ($response and exists $response->{error}) {
            BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $pricing_channel->{$serialized_args}->{$amount}->{uuid});
            # in pricer_dameon everything happens in Eng to maximize the collisions. If translations has params it will come as message_to_client_array.
            # eitherway it need l10n here.
            if ($response->{error}->{message_to_client_array}) {
                $response->{error}->{message_to_client} = $c->l(@{$response->{error}->{message_to_client_array}});
            } else {
                $response->{error}->{message_to_client} = $c->l($response->{error}->{message_to_client});
            }

            my $err = $c->new_error('proposal', $response->{error}->{code}, $response->{error}->{message_to_client});
            $err->{error}->{details} = $response->{error}->{details} if (exists $response->{error}->{details});
            $results = $err;
        } else {
            if ($response->{shortcode}) { # bid
                $results = {
                    msg_type   => 'proposal_open_contract',
                    'proposal_open_contract' => {
                        %$response,
                    },
                };
                $results->{echo_req} = $pricing_channel->{$serialized_args}->{$amount}->{args};
                if (my $passthrough = $pricing_channel->{$serialized_args}->{$amount}->{args}->{passthrough}) {
                    $results->{passthrough} = $passthrough;
                }
                if (my $req_id = $pricing_channel->{$serialized_args}->{$amount}->{args}->{req_id}) {
                    $results->{req_id} = $req_id;
                }
            } else { # ask
                delete $response->{longcode};
                my $adjusted_results = _price_stream_results_adjustment($pricing_channel->{$serialized_args}->{$amount}->{args}, $response, $amount);

                if (my $ref = $adjusted_results->{error}) {
                    my $err = $c->new_error('proposal', $ref->{code}, $ref->{message_to_client});
                    $err->{error}->{details} = $ref->{details} if exists $ref->{details};
                    $results = $err;
                } else {
                    $results = {
                        msg_type   => 'proposal',
                        'proposal' => {
                            id       => $pricing_channel->{$serialized_args}->{$amount}->{uuid},
                            longcode => $pricing_channel->{$serialized_args}->{$amount}->{longcode},
                            %$adjusted_results,
                        },
                    };
                }
                $results->{echo_req} = $pricing_channel->{$serialized_args}->{$amount}->{args};
                if (my $passthrough = $pricing_channel->{$serialized_args}->{$amount}->{args}->{passthrough}) {
                    $results->{passthrough} = $passthrough;
                }
                if (my $req_id = $pricing_channel->{$serialized_args}->{$amount}->{args}->{req_id}) {
                    $results->{req_id} = $req_id;
                }
            }
        }

        if ($c->stash('debug')) {
            $results->{debug} = {
                time   => $results->{price_stream}->{rpc_time},
                method => 'proposal',
            };
        }
        $c->send({json => $results});
    }
    return;
}

sub _price_stream_results_adjustment {
    my $orig_args = shift;
    my $results   = shift;
    my $amount    = shift;

    # skips for spreads
    return $results if first { $orig_args->{contract_type} eq $_ } qw(SPREADU SPREADD);

    my $contract_parameters = BOM::RPC::v3::Contract::prepare_ask($orig_args);
    # overrides the theo_probability_value which take the most calculation time.
    $contract_parameters->{theo_probability_value} = $results->{theo_probability};
    $contract_parameters->{app_markup_percentage}  = $orig_args->{app_markup_percentage};
    my $contract = BOM::RPC::v3::Contract::create_contract($contract_parameters);

    if (my $error = $contract->validate_price) {
        return {
            error => {
                message_to_client => $error->{message_to_client},
                code              => 'ContractBuyValidationError',
                details           => {
                    longcode      => $contract->longcode,
                    display_value => $contract->ask_price,
                    payout        => $contract->payout,
                },
            }};
    }

    $results->{ask_price} = $results->{display_value} = $contract->ask_price;
    $results->{payout} = $contract->payout;
    #cleanup
    delete $results->{theo_probability};

    return $results;
}

1;
