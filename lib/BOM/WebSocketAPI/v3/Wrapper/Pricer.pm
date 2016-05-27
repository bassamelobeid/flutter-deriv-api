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
    my ($c, $req_storage) = @_;

    my $args     = $req_storage->{args};
    my $symbol   = $args->{symbol};
    my $response = BOM::RPC::v3::Contract::validate_symbol($symbol);
    if ($response and exists $response->{error}) {
        return $c->new_error('price_stream', $response->{error}->{code}, $c->l($response->{error}->{message}, $symbol));
    } else {
        my $id;
        if ($args->{subscribe} and $args->{subscribe} == 1 and not $id = _pricing_channel($c, 'subscribe', $args)) {
            return $c->new_error('price_stream',
                'AlreadySubscribedOrLimit', $c->l('You are either already subscribed or you have reached the limit for proposal subscription.'));
        }
        _send_ask($c, $id, $args);
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

    if ($pricing_channel->{$serialized_args} and $pricing_channel->{$serialized_args}->{$args->{amount}}) {
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

    $pricing_channel->{$serialized_args}->{$args->{amount}}->{uuid} = $uuid;
    $pricing_channel->{$serialized_args}->{$args->{amount}}->{args} = $args;
    $pricing_channel->{$serialized_args}->{channel_name}            = $rp->_processed_channel;
    $pricing_channel->{uuid}->{$uuid}->{serialized_args}            = $serialized_args;
    $pricing_channel->{uuid}->{$uuid}->{amount}                     = $args->{amount};
    $pricing_channel->{uuid}->{$uuid}->{args}                       = $args;

    $c->stash('pricing_channel' => $pricing_channel);
    return $uuid;
}

sub _send_ask {
    my ($c, $id, $req_storage) = @_;

    $c->call_rpc({
            args     => $req_storage,
            id       => $id,
            method   => 'send_ask',
            msg_type => 'price_stream',
            error    => sub {
                my ($c, $rpc_response, $req_storage) = @_;
                BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $req_storage->{id});
            },
            response => sub {
                my ($rpc_response, $api_response, $req_storage) = @_;

                if ($api_response->{error}) {
                    $api_response->{error}->{details} = $rpc_response->{error}->{details} if (exists $rpc_response->{error}->{details});
                } else {
                    $api_response->{proposal}->{id} = $req_storage->{id} if $req_storage->{id};
                }
                return $api_response;
            }
        });
    return;
}

sub process_pricing_events {
    my ($c, $message, $chan) = @_;

    return if not $message;

    my $response        = decode_json($message);
    my $serialized_args = $response->{data};

    my $pricing_channel = $c->stash('pricing_channel');
    return if not $pricing_channel or not $pricing_channel->{$serialized_args};

    if (not $c->stash->{last_pricer_expiry_update} or time - $c->stash->{last_pricer_expiry_update} > 30) {
        BOM::System::RedisReplicated::redis_pricer->expire($response->{key}, 60);
        $c->stash->{last_pricer_expiry_update} = time;
    }

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
                        id => $pricing_channel->{$serialized_args}->{$amount}->{uuid},
                        %$adjusted_results,
                    },
                };
            }
        }

        $results->{echo_req} = $pricing_channel->{$serialized_args}->{$amount}->{args};

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
        my $commission_markup = BOM::Product::Contract::Helper::commission({});
        my $payout            = roundnear(
            0.01,
            BOM::RPC::v3::Contract::calculate_payout({
                    theo_probability => $results->{theo_probability},
                    base_commission  => $results->{base_commission},
                    amount           => $amount,
                }));
        $amount                   = roundnear(0.01, $amount);
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
