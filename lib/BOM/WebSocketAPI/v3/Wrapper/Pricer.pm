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

                my $rpc_response = shift;
                if ($rpc_response and exists $rpc_response->{error}) {
                    my $err = $c->new_error('proposal', $rpc_response->{error}->{code}, $rpc_response->{error}->{message_to_client});
                    $err->{error}->{details} = $rpc_response->{error}->{details} if (exists $rpc_response->{error}->{details});
                    return $err;
                }
    
                my $uuid;
    
                if (not $uuid = _pricing_channel($c, 'subscribe', $args)) {
                    return $c->new_error('proposal',
                        'AlreadySubscribedOrLimit', $c->l('You are either already subscribed or you have reached the limit for proposal subscription.'));
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

    delete $args_hash{passthrough};
    delete $args_hash{req_id};

    $args_hash{language} = $c->stash('language') || 'EN';
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
        }

        $results->{echo_req} = $pricing_channel->{$serialized_args}->{$amount}->{args};
        if (my $passthrough = $pricing_channel->{$serialized_args}->{$amount}->{args}->{passthrough}) {
            $results->{passthrough} = $passthrough;
        }
        if (my $req_id = $pricing_channel->{$serialized_args}->{$amount}->{args}->{req_id}) {
            $results->{req_id} = $req_id;
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
