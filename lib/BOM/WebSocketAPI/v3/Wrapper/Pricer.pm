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

sub price_stream {
    my ($c, $args) = @_;

    my $symbol   = $args->{symbol};
    my $response = BOM::RPC::v3::Contract::validate_symbol($symbol);
    if ($response and exists $response->{error}) {
        return $c->new_error('price_stream', $response->{error}->{code}, $c->l($response->{error}->{message}, $symbol));
    } else {
        my $id;
        if ($args->{subscribe} == 1 and not $id = _pricing_channel($c, 'subscribe', $args)) {
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

    $args_hash{request_time} = gettimeofday;

    $args_hash{language} = $c->stash('language') || 'EN';
    my $serialized_args = _serialized_args(\%args_hash);

    my $pricing_channel = $c->stash('pricing_channel') || {};

    if ($pricing_channel->{$serialized_args} and $pricing_channel->{$serialized_args}->{$args->{amount}}) {
        return;
    }

    # Contracts that don't need streaming.
    my %skip_duration_list = map { $_ => 1 } qw(s m h);
    my %skip_symbol_list   = map { $_ => 1 } qw(R_100 R_50 R_25 R_75 RDBULL RDBEAR);
    my %skip_type_list     = map { $_ => 1 } qw(CALL PUT DIGITMATCH DIGITDIFF DIGITOVER DIGITUNDER DIGITODD DIGITEVEN);

    my $skip_symbols = ($skip_symbol_list{$args->{symbol}}) ? 1 : 0;
    my $atm_contract = ($args->{contract_type} =~ /^(CALL|PUT)$/ and not $args->{barrier}) ? 1 : 0;
    my $fixed_expiry = $args->{date_expiry} ? 1 : 0;
    my $skip_tick_expiry =
        ($skip_symbols and $skip_type_list{$args->{contract_type}} and $args->{duration_unit} eq 't');
    my $skip_intraday_atm_non_fixed_expiry =
        ($skip_symbols and $skip_duration_list{$args->{duration_unit}} and $atm_contract and not $fixed_expiry);

    my $uuid = Data::UUID->new->create_str();
    # We don't stream but still return the UUID to keep it unifom.
    if ($skip_tick_expiry or $skip_intraday_atm_non_fixed_expiry) {
        return $uuid;
    }

    if (not $pricing_channel->{$serialized_args}) {
        my $rp = Mojo::Redis::Processor->new({
            'write_conn' => BOM::System::RedisReplicated::redis_pricer,
            'read_conn'  => BOM::System::RedisReplicated::redis_pricer,
            data         => $serialized_args,
            trigger      => 'FEED::' . $args->{symbol},
        });
        $rp->send();
        $c->stash('redis_pricer')->subscribe([$rp->_processed_channel], sub { });

        $pricing_channel->{$serialized_args}->{$args->{amount}}->{uuid} = $uuid;
        $pricing_channel->{$serialized_args}->{$args->{amount}}->{args} = $args;
        $pricing_channel->{$serialized_args}->{channel_name}            = $rp->_processed_channel;

        $c->stash('pricing_channel' => $pricing_channel);
    }
    return $uuid;
}

sub _send_ask {
    my ($c, $id, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'send_ask',
        sub {
            my $response = shift;
            if ($response and exists $response->{error}) {
                BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id);
                my $err = $c->new_error('price_stream', $response->{error}->{code}, $response->{error}->{message_to_client});
                $err->{error}->{details} = $response->{error}->{details} if (exists $response->{error}->{details});
                return $err;
            }
            delete $response->{longcode};
            return {
                msg_type => 'price_stream',
                price_stream => {($id ? (id => $id) : ()), %$response}};
        },
        {args => $args},
        'price_stream'
    );
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
        BOM::System::RedisReplicated::redis_write->expire($response->{key}, 60);
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
            $results = {
                msg_type     => 'price_stream',
                price_stream => $response,
            };

            $results = _price_stream_results_adjustment($pricing_channel->{$serialized_args}->{$amount}->{args}, $results, $amount);

            $results->{price_stream}->{id} = $pricing_channel->{$serialized_args}->{$amount}->{uuid};
        }

        $results->{echo_req} = $pricing_channel->{$serialized_args}->{$amount}->{args};
        $c->send({json => $results});
    }
    return;
}

sub _price_stream_results_adjustment {
    my $orig_args = shift;
    my $results   = shift;
    my $amount    = shift;
    # For non spread
    if ($orig_args->{basis}) {
        $results->{price_stream}->{ask_price} *= $amount / 1000;
        $results->{price_stream}->{ask_price} = roundnear(0.01, $results->{price_stream}->{ask_price});

        $results->{price_stream}->{display_value} *= $amount / 1000;
        $results->{price_stream}->{display_value} = roundnear(0.01, $results->{price_stream}->{display_value});
    }
    return $results;
}

1;
