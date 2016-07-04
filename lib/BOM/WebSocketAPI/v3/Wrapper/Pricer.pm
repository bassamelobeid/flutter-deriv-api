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
use Time::HiRes qw(gettimeofday);
use BOM::WebSocketAPI::v3::Wrapper::Streamer;
use Math::Util::CalculatedValue::Validatable;
use Data::Dumper;

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

    delete $req_storage->{instead_of_forward};
    $req_storage->{rpc_response_cb} = \&proposal_open_contract_cb;
    $c->call_rpc($req_storage);

    return;
}

sub proposal_open_contract_cb {
    my ($c, $response, $req_storage) = @_;

    my $args = $req_storage->{args};
    #warn "POC_cb: args: ".Dumper($args);
    #warn "POC_CB: resp: ".Dumper($response);
    #warn "POC_CB: req_storage : ".Dumper($req_storage);
    warn "POC_CB: req_storage : ".Dumper({map { m/validator/ ? () : ($_=>$req_storage->{$_})} keys %$req_storage});
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
                    my $uuid;
                    if (    exists $args->{subscribe}
                        and $args->{subscribe} eq '1'
                        and not $response->{$contract_id}->{is_expired}
                        and not $response->{$contract_id}->{is_sold})
                    {
                        $uuid = Data::UUID->new->create_str();

                        my $subscribe_args = {
                            subscribe       => 1,
                            echo_req        => {%$args},
                            account_id      => delete $response->{$contract_id}->{account_id},
                            id              => $uuid,
                            short_code      => $response->{$contract_id}->{shortcode},
                            contract_id     => $response->{$contract_id}->{contract_id},
                            currency        => $response->{$contract_id}->{currency},
                            is_sold         => $response->{$contract_id}->{is_sold},
                            sell_time       => $response->{$contract_id}->{sell_time},
                            sell_price      => $response->{$contract_id}->{sell_price},
                            passthrough     => $args->{passthrough},
                            transaction_ids => $response->{$contract_id}->{transaction_ids},
                            purchase_time   => $response->{$contract_id}->{purchase_time},
                            buy_price       => $response->{$contract_id}->{buy_price},
                        };

                        if (not _pricing_channel_for_bid($c, 'subscribe', $subscribe_args)) {
                            warn "Error - not subscribed!";
                            return $c->new_error('proposal_open_contract',
                                    'AlreadySubscribedOrLimit', $c->l('You are either already subscribed or you have reached the limit for proposal_open_contract subscription.'));
                        }

                        # subscribe to transaction channel as when contract is manually sold we need to cancel streaming
                        BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'subscribe', $subscribe_args->{account_id}, $uuid, $subscribe_args);
                    }
                    my $res = {$uuid ? (id => $uuid) : (), %{$response->{$contract_id}}};
                    #warn "proposal_open_contract send to WS: ".Dumper($res);
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

                #warn "Pricer ASK going to _pricing_channel with args: ". Dumper($args);
                if (not $uuid = _pricing_channel_for_ask($c, 'subscribe', $args)) {
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

sub _pricing_channel_for_ask {
    my ($c, $subs, $args) = @_;

    my %args_hash = %{$args};

    if ($args_hash{basis}) {
        $args_hash{amount} = 1000;
        $args_hash{basis}  = 'payout';
    }

    delete $args_hash{passthrough};
    delete $args_hash{req_id};

    $args_hash{language} = $c->stash('language') || 'EN';
    $args_hash{rpc_call} = 'send_ask';
    my $serialized_args = _serialized_args(\%args_hash);

    my $pricing_channel = $c->stash('pricing_channel') || {};

    my $amount = $args->{amount_per_point} || $args->{amount};

    # already subscribed
    if ($pricing_channel->{$serialized_args} and $pricing_channel->{$serialized_args}->{$amount}) {
        return;
    }

    my $uuid = Data::UUID->new->create_str();

    # subscribe if it is not already subscribed
    if (    not $pricing_channel->{$serialized_args}
        and not BOM::WebSocketAPI::v3::Wrapper::Streamer::_skip_streaming($args)
        and $args->{subscribe}
        and $args->{subscribe} == 1)
    {
        $c->redis_pricer->set($serialized_args, 1);
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

sub _pricing_channel_for_bid {
    my ($c, $subs, $args) = @_;

    warn "_pricing_channel_for_bid : args: ".Dumper($args);
    my %args_hash;
    $args_hash{$_} = $args->{$_} for qw(short_code contract_id currency is_sold sell_time passthrough);
    $args_hash{language} = $c->stash('language') || 'EN';
    $args_hash{rpc_call} = 'get_bid';
    my $serialized_args = _serialized_args(\%args_hash);
    warn "Seria Ags: $serialized_args\n";

    my $pricing_channel = $c->stash('pricing_channel') || {};

    return if $pricing_channel->{$serialized_args};

    my $uuid = $args->{id};

    # subscribe if it is not already subscribed
    if ( exists $args->{subscribe} and $args->{subscribe} == 1)
    {
        $c->redis_pricer->set($serialized_args, 1);
        $c->stash('redis_pricer')->subscribe([$serialized_args], sub { });
    }

    $pricing_channel->{$serialized_args}->{uuid}         = $uuid;
    $pricing_channel->{$serialized_args}->{args}         = $args;
    $pricing_channel->{uuid}->{$uuid}->{serialized_args} = $serialized_args;
    $pricing_channel->{uuid}->{$uuid}->{args}            = $args;

    $c->stash('pricing_channel' => $pricing_channel);
    return $uuid;
}

sub process_pricing_events {
    my ($c, $message, $channel_name) = @_;

    # in case that it is a spread
    return if not $message or not $c->tx;
    my $pricing_channel = $c->stash('pricing_channel');
    return if not $pricing_channel or not $pricing_channel->{$channel_name};

    my $response        = decode_json($message);
    my $rpc_call        = delete $response->{rpc_call};

    if ($rpc_call eq 'send_ask') {
        process_ask_event($c, $response, $channel_name, $pricing_channel);
    } elsif ($rpc_call eq 'get_bid') {
        process_bid_event($c, $response, $channel_name, $pricing_channel);
    }
    return;
}

sub process_bid_event {
    my ($c, $response, $serialized_args, $pricing_channel) = @_;
    my $results;
    if ($response and exists $response->{error}) {
        BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $pricing_channel->{$serialized_args}->{uuid});
        if ($response->{error}->{message_to_client_array}) {
            $response->{error}->{message_to_client} = $c->l(@{$response->{error}->{message_to_client_array}});
        } else {
            $response->{error}->{message_to_client} = $c->l($response->{error}->{message_to_client});
        }

        my $err = $c->new_error('proposal_open_contract', $response->{error}->{code}, $response->{error}->{message_to_client});
        $err->{error}->{details} = $response->{error}->{details} if (exists $response->{error}->{details});
        $results = $err;
    } else {
        my $passed_fields            = $pricing_channel->{$serialized_args}->{args};
        $response->{id}              = $passed_fields->{id};
        $response->{transaction_ids} = $passed_fields->{transaction_ids};
        $response->{buy_price}       = $passed_fields->{buy_price};
        $response->{purchase_time}   = $passed_fields->{purchase_time};
        $response->{sell_price}      = $passed_fields->{sell_price} if exists $passed_fields->{sell_price};
        $response->{sell_time}       = $passed_fields->{sell_time} if exists $passed_fields->{sell_time};
        $results = {
            msg_type   => 'proposal_open_contract',
            'proposal_open_contract' => {
                %$response,
            },
        };
        $results->{echo_req} = $pricing_channel->{$serialized_args}->{args}->{echo_req};
        if (my $passthrough = $pricing_channel->{$serialized_args}->{args}->{echo_req}->{passthrough}) {
            $results->{passthrough} = $passthrough;
        }
    }
    #warn "process_bid_send to WS: ".Dumper($results);
    $c->send({json => $results});
    return;
}

sub process_ask_event {
    my ($c, $response, $serialized_args, $pricing_channel) = @_;

    my $theo_probability = $response->{theo_probability};
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
            delete $response->{longcode};
            my $adjusted_results = _price_stream_results_adjustment($pricing_channel->{$serialized_args}->{$amount}->{args}, $response, $theo_probability);

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
    my $orig_args             = shift;
    my $results               = shift;
    my $resp_theo_probability = shift;

    # skips for spreads
    return $results if first { $orig_args->{contract_type} eq $_ } qw(SPREADU SPREADD);

    my $contract_parameters = BOM::RPC::v3::Contract::prepare_ask($orig_args);
    # overrides the theo_probability which take the most calculation time.
    # theo_probability is a calculated value (CV), overwrite it with CV object.
    my $theo_probability = Math::Util::CalculatedValue::Validatable->new({
        name        => 'theo_probability',
        description => 'theorectical value of a contract',
        set_by      => 'Pricer Daemon',
        base_amount => $resp_theo_probability,
        minimum     => 0,
        maximum     => 1,
    });
    $contract_parameters->{theo_probability}      = $theo_probability;
    $contract_parameters->{app_markup_percentage} = $orig_args->{app_markup_percentage};
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
