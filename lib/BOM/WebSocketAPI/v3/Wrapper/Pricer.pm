package BOM::WebSocketAPI::v3::Wrapper::Pricer;

use strict;
use warnings;
use JSON;
use List::Util qw(first);
use Format::Util::Numbers qw(roundnear);
use BOM::WebSocketAPI::v3::Wrapper::System;
use Mojo::Redis::Processor;
use JSON::XS qw(encode_json decode_json);
use Time::HiRes qw(gettimeofday);
use BOM::WebSocketAPI::v3::Wrapper::Streamer;
use Math::Util::CalculatedValue::Validatable;
use BOM::RPC::v3::Contract;

sub proposal {
    my ($c, $req_storage) = @_;

    my $args = $req_storage->{args};

    $c->call_rpc({
            args     => $args,
            method   => 'send_ask',
            msg_type => 'proposal',
            success  => sub {
                my ($c, $rpc_response, $req_storage) = @_;
                my $cache = {
                    longcode            => $rpc_response->{longcode},
                    contract_parameters => delete $rpc_response->{contract_parameters}};
                $req_storage->{uuid} = _pricing_channel_for_ask($c, 'subscribe', $req_storage->{args}, $cache);
            },
            response => sub {
                my ($rpc_response, $api_response, $req_storage) = @_;
                return $api_response if $rpc_response->{error};

                if (my $passthrough = $req_storage->{args}->{passthrough}) {
                    $api_response->{passthrough} = $passthrough;
                }
                if (my $uuid = $req_storage->{uuid}) {
                    $api_response->{proposal}->{id} = $uuid;
                } else {
                    $api_response = $c->new_error('proposal', 'AlreadySubscribed', $c->l('You are already subscribed to proposal.'));
                }
                return $api_response;
            },
        });
    return;
}

sub proposal_open_contract {
    my ($c, $response, $req_storage) = @_;

    my $args         = $req_storage->{args};
    my @contract_ids = keys %$response;
    if (scalar @contract_ids) {
        my $send_details = sub {
            my $result      = shift;
            my $passthrough = $req_storage->{args}->{passthrough};
            delete $result->{rpc_time};
            $c->send({
                    json => {
                        msg_type               => 'proposal_open_contract',
                        proposal_open_contract => {%$result}
                    },
                    $passthrough ? (passthrough => $passthrough) : (),
                },
                $req_storage
            );
        };
        foreach my $contract_id (@contract_ids) {
            if (exists $response->{$contract_id}->{error}) {
                my $error = $c->new_error('proposal_open_contract',
                    'ContractValidationError', $c->l($response->{$contract_id}->{error}->{message_to_client}));
                $c->send({json => $error}, $req_storage);
            } else {
                my $uuid;

                if (    exists $args->{subscribe}
                    and $args->{subscribe} eq '1'
                    and not $response->{$contract_id}->{is_expired}
                    and not $response->{$contract_id}->{is_sold})
                {
                    my $account_id = delete $response->{$contract_id}->{account_id};
                    my $cache      = {
                        account_id      => $account_id,
                        short_code      => $response->{$contract_id}->{shortcode},
                        contract_id     => $response->{$contract_id}->{contract_id},
                        currency        => $response->{$contract_id}->{currency},
                        buy_price       => $response->{$contract_id}->{buy_price},
                        sell_price      => $response->{$contract_id}->{sell_price},
                        sell_time       => $response->{$contract_id}->{sell_time},
                        purchase_time   => $response->{$contract_id}->{purchase_time},
                        is_sold         => $response->{$contract_id}->{is_sold},
                        transaction_ids => $response->{$contract_id}->{transaction_ids},
                    };

                    if (not $uuid = _pricing_channel_for_bid($c, 'subscribe', $args, $cache)) {
                        my $error =
                            $c->new_error('proposal_open_contract',
                            'AlreadySubscribedOrLimit',
                            $c->l('You are either already subscribed or you have reached the limit for proposal_open_contract subscription.'));
                        $c->send({json => $error}, $req_storage);
                        return;
                    } else {
                        # subscribe to transaction channel as when contract is manually sold we need to cancel streaming
                        BOM::WebSocketAPI::v3::Wrapper::Streamer::_transaction_channel($c, 'subscribe', $account_id,
                            $uuid, {contract_id => $contract_id});
                    }
                }
                my $res = {$uuid ? (id => $uuid) : (), %{$response->{$contract_id}}};
                $send_details->($res);
            }
        }
        return;
    } else {
        return {
            msg_type               => 'proposal_open_contract',
            proposal_open_contract => {}};
    }
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
    my ($c, $subs, $args, $cache) = @_;
    my $price_daemon_cmd = 'price';

    my %args_hash = %{$args};

    if ($args_hash{basis}) {
        $args_hash{amount} = 1000;
        $args_hash{basis}  = 'payout';
    }

    delete $args_hash{passthrough};
    delete $args_hash{req_id};

    $args_hash{language} = $c->stash('language') || 'EN';
    $args_hash{price_daemon_cmd} = $price_daemon_cmd;
    my $redis_channel = _serialized_args(\%args_hash);
    my $subchannel = $args->{amount_per_point} || $args->{amount};

    my $skip = BOM::WebSocketAPI::v3::Wrapper::Streamer::_skip_streaming($args);

    # uuid is needed regardles redis subscription
    return _create_pricer_channel($c, $args, $redis_channel, $subchannel, $price_daemon_cmd, $cache, $skip);
}

sub _pricing_channel_for_bid {
    my ($c, $subs, $args, $cache) = @_;
    my $price_daemon_cmd = 'bid';

    my %hash;
    $hash{$_} = delete $cache->{$_} for qw(short_code contract_id currency is_sold sell_time);
    $hash{language} = $c->stash('language') || 'EN';
    $hash{price_daemon_cmd} = $price_daemon_cmd;
    my $redis_channel = _serialized_args(\%hash);

    %hash                 = ();
    %hash                 = map { $_ =~ /req_id|passthrough/ ? () : ($_ => $args->{$_}) } keys %$args;
    $hash{account_id}     = delete $cache->{account_id};
    $hash{transaction_id} = $cache->{transaction_ids}->{buy};                                            # transaction is going to be stored
    my $subchannel = _serialized_args(\%hash);

    return _create_pricer_channel($c, $args, $redis_channel, $subchannel, $price_daemon_cmd, $cache);
}

sub _create_pricer_channel {
    my ($c, $args, $redis_channel, $subchannel, $price_daemon_cmd, $cache, $skip_redis_subscr) = @_;

    my $pricing_channel = $c->stash('pricing_channel') || {};

    # already subscribed
    if (exists $pricing_channel->{$redis_channel} and exists $pricing_channel->{$redis_channel}->{$subchannel}) {
        return;
    }

    my $uuid = &BOM::WebSocketAPI::v3::Wrapper::Streamer::_generate_uuid_string();

    # subscribe if it is not already subscribed
    if (    exists $args->{subscribe}
        and $args->{subscribe} == 1
        and not exists $pricing_channel->{$redis_channel}
        and not $skip_redis_subscr)
    {
        $c->redis_pricer->set($redis_channel, 1);
        $c->stash('redis_pricer')->subscribe([$redis_channel], sub { });
    }

    $pricing_channel->{$redis_channel}->{$subchannel}->{uuid}          = $uuid;
    $pricing_channel->{$redis_channel}->{$subchannel}->{args}          = $args;
    $pricing_channel->{$redis_channel}->{$subchannel}->{cache}         = $cache;
    $pricing_channel->{uuid}->{$uuid}->{redis_channel}                 = $redis_channel;
    $pricing_channel->{uuid}->{$uuid}->{subchannel}                    = $subchannel;
    $pricing_channel->{uuid}->{$uuid}->{price_daemon_cmd}              = $price_daemon_cmd;
    $pricing_channel->{uuid}->{$uuid}->{args}                          = $args;               # for buy rpc call
    $pricing_channel->{uuid}->{$uuid}->{cache}                         = $cache;
    $pricing_channel->{price_daemon_cmd}->{$price_daemon_cmd}->{$uuid} = 1;                   # for forget_all

    $c->stash('pricing_channel' => $pricing_channel);
    return $uuid;
}

sub process_pricing_events {
    my ($c, $message, $channel_name) = @_;

    # in case that it is a spread
    return if not $message or not $c->tx;
    my $pricing_channel = $c->stash('pricing_channel');
    return if not $pricing_channel or not $pricing_channel->{$channel_name};

    my $response         = decode_json($message);
    my $price_daemon_cmd = delete $response->{price_daemon_cmd};

    my %handler = (
        price => \&process_ask_event,
        bid   => \&process_bid_event,
    );

    $handler{$price_daemon_cmd}->($c, $response, $channel_name, $pricing_channel);

    return;
}

sub process_bid_event {
    my ($c, $response, $redis_channel, $pricing_channel) = @_;
    for my $subchannel (keys %{$pricing_channel->{$redis_channel}}) {
        my $results;
        if ($response and exists $response->{error}) {
            BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $pricing_channel->{$redis_channel}->{uuid});
            if ($response->{error}->{message_to_client_array}) {
                $response->{error}->{message_to_client} = $c->l(@{$response->{error}->{message_to_client_array}});
            } else {
                $response->{error}->{message_to_client} = $c->l($response->{error}->{message_to_client});
            }

            $results = $c->new_error('proposal_open_contract', $response->{error}->{code}, $response->{error}->{message_to_client});
            $results->{error}->{details} = $response->{error}->{details} if (exists $response->{error}->{details});
        } else {
            my $passed_fields = $pricing_channel->{$redis_channel}->{$subchannel}->{cache};
            $response->{id}              = $pricing_channel->{$redis_channel}->{$subchannel}->{uuid};
            $response->{transaction_ids} = $passed_fields->{transaction_ids};
            $response->{buy_price}       = $passed_fields->{buy_price};
            $response->{purchase_time}   = $passed_fields->{purchase_time};
            $results                     = {
                msg_type                 => 'proposal_open_contract',
                'proposal_open_contract' => {%$response,},
            };
            _prepare_results($results, $pricing_channel, $redis_channel, $subchannel);
        }
        if ($c->stash('debug')) {
            $results->{debug} = {
                time   => $results->{proposal_open_contract}->{rpc_time},
                method => 'proposal_open_contract',
            };
        }
        delete $results->{proposal_open_contract}->{rpc_time};
        $c->send({json => $results});
    }
    return;
}

sub process_ask_event {
    my ($c, $response, $redis_channel, $pricing_channel) = @_;

    my $theo_probability = $response->{theo_probability};
    foreach my $subchannel (keys %{$pricing_channel->{$redis_channel}}) {
        my $results;
        if ($response and exists $response->{error}) {
            BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $pricing_channel->{$redis_channel}->{$subchannel}->{uuid});
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
            my $adjusted_results = _price_stream_results_adjustment(
                $pricing_channel->{$redis_channel}->{$subchannel}->{args},
                $pricing_channel->{$redis_channel}->{$subchannel}->{cache}->{contract_parameters},
                $response, $theo_probability
            );
            if (my $ref = $adjusted_results->{error}) {
                my $err = $c->new_error('proposal', $ref->{code}, $ref->{message_to_client});
                $err->{error}->{details} = $ref->{details} if exists $ref->{details};
                $results = $err;
            } else {
                $results = {
                    msg_type   => 'proposal',
                    'proposal' => {
                        id       => $pricing_channel->{$redis_channel}->{$subchannel}->{uuid},
                        longcode => $pricing_channel->{$redis_channel}->{$subchannel}->{cache}->{longcode},
                        %$adjusted_results,
                    },
                };
            }
            _prepare_results($results, $pricing_channel, $redis_channel, $subchannel);
        }
        if ($c->stash('debug')) {
            $results->{debug} = {
                time   => $results->{proposal}->{rpc_time},
                method => 'proposal',
            };
        }
        delete $results->{proposal}->{$_} for qw(contract_parameters rpc_time);
        $c->send({json => $results});
    }
    return;
}

sub _prepare_results {
    my ($results, $pricing_channel, $redis_channel, $subchannel) = @_;
    $results->{echo_req} = $pricing_channel->{$redis_channel}->{$subchannel}->{args};
    if (my $passthrough = $pricing_channel->{$redis_channel}->{$subchannel}->{args}->{passthrough}) {
        $results->{passthrough} = $passthrough;
    }
    if (my $req_id = $pricing_channel->{$redis_channel}->{$subchannel}->{args}->{req_id}) {
        $results->{req_id} = $req_id;
    }
    return;
}

sub _price_stream_results_adjustment {
    my $orig_args             = shift;
    my $contract_parameters   = shift;
    my $results               = shift;
    my $resp_theo_probability = shift;

    # skips for spreads
    return $results if first { $orig_args->{contract_type} eq $_ } qw(SPREADU SPREADD);

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

sub send_proposal_open_contract_last_time {
    my ($c, $args) = @_;
    my $uuid = $args->{uuid};

    my $pricing_channel = $c->stash('pricing_channel');
    return if not $pricing_channel or not $pricing_channel->{uuid}->{$uuid};
    my $cache = $pricing_channel->{uuid}->{$uuid}->{cache};

    $c->call_rpc({
            args        => $pricing_channel->{uuid}->{$uuid}->{args},
            method      => 'get_bid',
            msg_type    => 'proposal_open_contract',
            call_params => {
                short_code  => $args->{short_code},
                contract_id => $args->{financial_market_bet_id},
                currency    => $args->{currency_code},
                sell_time   => $args->{sell_time},
                is_sold     => 1,
            },
            success => sub {
                my ($c, $rpc_response) = @_;

                $rpc_response->{buy_price}               = $cache->{buy_price};
                $rpc_response->{purchase_time}           = $cache->{purchase_time};
                $rpc_response->{transaction_ids}         = $cache->{transaction_ids};
                $rpc_response->{transaction_ids}->{sell} = $args->{id};
                $rpc_response->{sell_price}              = sprintf('%.2f', $args->{amount});
                $rpc_response->{sell_time}               = $args->{sell_time};

                # cancel proposal open contract streaming which will cancel transaction subscription also
                BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $uuid);
            },
            error => sub {
                BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $uuid);
            }
        });
    return;
}

1;
