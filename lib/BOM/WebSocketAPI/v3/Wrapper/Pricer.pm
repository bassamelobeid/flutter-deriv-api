package BOM::WebSocketAPI::v3::Wrapper::Pricer;

use strict;
use warnings;
use JSON;
use Data::UUID;
use Format::Util::Numbers qw(roundnear);
use BOM::RPC::v3::Contract;
use BOM::WebSocketAPI::v3::Wrapper::System;
use Mojo::Redis::Processor;
use JSON::XS qw(encode_json decode_json);
use BOM::System::RedisReplicated;
use Time::HiRes qw(gettimeofday);
use BOM::WebSocketAPI::v3::Wrapper::Streamer;

sub price_stream {
    my ($c, $args) = @_;

    my $symbol   = $args->{symbol};
    my $response = BOM::RPC::v3::Contract::validate_symbol($symbol);
    if ($response and exists $response->{error}) {
        return $c->new_error('price_stream', $response->{error}->{code}, $c->l($response->{error}->{message}, $symbol));
    } else {
        my $uuid;
        if ($args->{subscribe} and $args->{subscribe} == 1 and not $uuid = _pricing_channel($c, 'subscribe', $args)) {
            return $c->new_error('price_stream',
                'AlreadySubscribedOrLimit', $c->l('You are either already subscribed or you have reached the limit for proposal subscription.'));
        }
        _send_ask($c, $uuid, $args);
    }
    return;
}

sub _serialized_args {
    my $h = shift;
    my @a = ();
    foreach my $k (sort keys %$h) {
        push @a, ($k, $h->{$k});
    }
    return encode_json(\@a);
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

    if ($pricing_channel->{$serialized_args} and $pricing_channel->{$serialized_args}->{$amount}) {
        return;
    }

    my $uuid = Data::UUID->new->create_str();

    my $rp = Mojo::Redis::Processor->new({
        'write_conn' => BOM::System::RedisReplicated::redis_pricer,
        'read_conn'  => BOM::System::RedisReplicated::redis_pricer,
        data         => $serialized_args,
        trigger      => 'FEED::' . $args->{symbol},
    });

    # subscribe if it is not already subscribed
    if (not $pricing_channel->{$serialized_args} and not BOM::WebSocketAPI::v3::Wrapper::Streamer::_skip_streaming($args)) {
        $rp->send();
        $c->stash('redis_pricer')->subscribe([$rp->_processed_channel], sub { });

        my $request_time = gettimeofday;
        BOM::System::RedisReplicated::redis_pricer->set($rp->_processed_channel, $request_time);
        BOM::System::RedisReplicated::redis_pricer->expire($rp->_processed_channel, 60);
    }

    $pricing_channel->{$serialized_args}->{$amount}->{uuid} = $uuid;
    $pricing_channel->{$serialized_args}->{$amount}->{args} = $args;
    $pricing_channel->{$serialized_args}->{channel_name}    = $rp->_processed_channel;
    $pricing_channel->{uuid}->{$uuid}->{serialized_args}    = $serialized_args;
    $pricing_channel->{uuid}->{$uuid}->{amount}             = $amount;
    $pricing_channel->{uuid}->{$uuid}->{args}               = $args;

    $c->stash('pricing_channel' => $pricing_channel);
    return $uuid;
}

sub _send_ask {
    my ($c, $uuid, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'send_ask',
        sub {
            my $response = shift;
            if ($response and exists $response->{error}) {
                BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $uuid);
                my $err = $c->new_error('price_stream', $response->{error}->{code}, $response->{error}->{message_to_client});
                $err->{error}->{details} = $response->{error}->{details} if (exists $response->{error}->{details});
                return $err;
            }
            my $pricing_channel = $c->stash('pricing_channel');
            # if uuid is set (means subscribe:1), and channel stil exists we cache the longcode here (reposnse from rpc) to add them to responses from pricer_daemon.
            if ($uuid and exists $pricing_channel->{uuid}->{$uuid}) {
                my $serialized_args = $pricing_channel->{uuid}->{$uuid}->{serialized_args};
                my $amount = $args->{amount_per_point} || $args->{amount};
                $pricing_channel->{$serialized_args}->{$amount}->{longcode} = $response->{longcode};
                $c->stash('pricing_channel' => $pricing_channel);
            }
            return {
                msg_type => 'price_stream',
                price_stream => {($uuid ? (id => $uuid) : ()), %$response}};
        },
        {args => $args},
        'price_stream'
    );
    return;
}

sub process_pricing_events {
    my ($c, $message, $chan) = @_;

    # in case that it is a spread
    return if not $message or not $c->tx;

    my $response        = decode_json($message);
    my $serialized_args = $response->{data};

    my $pricing_channel = $c->stash('pricing_channel');
    return if not $pricing_channel or not $pricing_channel->{$serialized_args};

    delete $response->{data};
    delete $response->{key};

    foreach my $amount (keys %{$pricing_channel->{$serialized_args}}) {
        next if $amount eq 'channel_name';
        my $results;
        if ($response and exists $response->{error}) {
            $c->stash('redis')->subscribe([$pricing_channel->{$serialized_args}->{channel_name}]);
            my $err = $c->new_error('price_stream', $response->{error}->{code}, $response->{error}->{message_to_client});
            $err->{error}->{details} = $response->{error}->{details} if (exists $response->{error}->{details});
            $results = $err;
        } else {
            my $adjusted_results = _price_stream_results_adjustment($pricing_channel->{$serialized_args}->{$amount}->{args}, $response, $amount);

            if (my $ref = $adjusted_results->{error}) {
                my $err = $c->new_error('price_stream', $ref->{code}, $ref->{message_to_client});
                $err->{error}->{details} = $ref->{details} if exists $ref->{details};
                $results = $err;
            } else {
                $results = {
                    msg_type     => 'price_stream',
                    price_stream => {
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
                time   => 1000 * $results->{price_stream}->{rpc_time},
                method => 'price_stream',
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

    return $results if not $orig_args->{basis};

    # For non spread
    if ($orig_args->{basis} eq 'payout') {
        my $ask_price = BOM::RPC::v3::Contract::calculate_ask_price({
            theo_probability      => $results->{theo_probability},
            base_commission       => $results->{base_commission},
            probability_threshold => $results->{probability_threshold},
            amount                => $amount,
        });
        $results->{ask_price}     = roundnear(0.01, $ask_price);
        $results->{display_value} = roundnear(0.01, $ask_price);
        $results->{payout}        = roundnear(0.01, $amount);
    } elsif ($orig_args->{basis} eq 'stake') {
        my $payout = roundnear(
            0.01,
            BOM::RPC::v3::Contract::calculate_payout({
                    theo_probability => $results->{theo_probability},
                    base_commission  => $results->{base_commission},
                    amount           => $amount,
                }));
        $results->{ask_price}     = roundnear(0.01, $amount);
        $results->{display_value} = roundnear(0.01, $amount);
        $results->{payout}        = roundnear(0.01, $payout);
    }

    if (
        my $error = BOM::RPC::v3::Contract::validate_price({
                ask_price         => $results->{ask_price},
                payout            => $results->{payout},
                minimum_ask_price => $results->{minimum_stake},
                maximum_payout    => $results->{maximum_payout}}))
    {
        return {
            error => {
                message_to_client => $error->{message_to_client},
                code              => 'ContractBuyValidationError',
                details           => {
                    longcode      => $results->{longcode},
                    display_value => $results->{display_value},
                },
            }};
    }

    # cleans up the response.
    delete $results->{$_} for qw(theo_probability base_commission probability_threshold minimum_stake maximum_payout);

    return $results;
}

1;
