package BOM::WebSocketAPI::v3::Wrapper::Streamer;

use strict;
use warnings;

use JSON;
use Data::UUID;

use BOM::RPC::v3::TickStreamer;
use BOM::RPC::v3::Contract;
use BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement;
use BOM::WebSocketAPI::v3::Wrapper::System;

sub ticks {
    my ($c, $args) = @_;

    my @symbols =
        (ref $args->{ticks}) ? @{$args->{ticks}} : ($args->{ticks});
    foreach my $symbol (@symbols) {
        my $response = BOM::RPC::v3::Contract::validate_underlying($symbol);
        if ($response and exists $response->{error}) {
            return $c->new_error('ticks', $response->{error}->{code}, $response->{error}->{message_to_client});
        } else {
            if (exists $args->{subscribe} and $args->{subscribe} eq '0') {
                _feed_channel($c, 'unsubscribe', $symbol, 'tick', $args);
            } else {
                my $uuid;
                if (not $uuid = _feed_channel($c, 'subscribe', $symbol, 'tick', $args)) {
                    return $c->new_error('ticks', 'AlreadySubscribed', $c->l('You are already subscribed to [_1]', $symbol));
                }
            }
        }
    }
    return;
}

sub ticks_history {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'ticks_history',
        sub {
            my $response = shift;
            if ($response and exists $response->{error}) {
                return $c->new_error('ticks_history', $response->{error}->{code}, $response->{error}->{message_to_client});
            }

            if (exists $args->{subscribe}) {
                if ($args->{subscribe} eq '1') {
                    if (not _feed_channel($c, 'subscribe', $args->{ticks_history}, $response->{publish}, $args)) {
                        return $c->new_error('ticks_history',
                            'AlreadySubscribed', $c->l('You are already subscribed to [_1]', $args->{ticks_history}));
                    }
                }
            }
            return {
                msg_type => $response->{type},
                %{$response->{data}}};
        },
        {args => $args});

    return;
}

sub proposal {
    my ($c, $args) = @_;

    my $symbol   = $args->{symbol};
    my $response = BOM::RPC::v3::Contract::validate_symbol($symbol);
    if ($response and exists $response->{error}) {
        return $c->new_error('proposal', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        my $id;
        $id = _feed_channel($c, 'subscribe', $symbol, 'proposal:' . JSON::to_json($args), $args);
        send_ask($c, $id, $args);
    }
    return;
}

sub send_ask {
    my ($c, $id, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'send_ask',
        sub {
            my $response = shift;
            if ($response and exists $response->{error}) {
                BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id);
                return $c->new_error('proposal', $response->{error}->{code}, $response->{error}->{message_to_client});
            }
            return {
                msg_type => 'proposal',
                proposal => {($id ? (id => $id) : ()), %$response}};
        },
        {args => $args});
    return;
}

sub process_realtime_events {
    my ($c, $message) = @_;

    my @m = split(';', $message);
    my $feed_channels_type = $c->stash('feed_channel_type');

    foreach my $channel (keys %{$feed_channels_type}) {
        $channel =~ /(.*);(.*)/;
        my $symbol    = $1;
        my $type      = $2;
        my $arguments = $feed_channels_type->{$channel}->{args};

        if ($type eq 'tick' and $m[0] eq $symbol) {
            $c->send({
                    json => {
                        msg_type => 'tick',
                        echo_req => $arguments,
                        (exists $arguments->{req_id})
                        ? (req_id => $arguments->{req_id})
                        : (),
                        tick => {
                            id     => $feed_channels_type->{$channel}->{uuid},
                            symbol => $symbol,
                            epoch  => $m[1],
                            quote  => BOM::Market::Underlying->new($symbol)->pipsized_value($m[2])}}}) if $c->tx;
        } elsif ($type =~ /^proposal:/ and $m[0] eq $symbol and exists $arguments->{subscribe} and $arguments->{subscribe} eq '1') {
            unless ($arguments->{symbol} =~ /^R_/ and $arguments->{duration_unit} eq 't') {
                send_ask($c, $feed_channels_type->{$channel}->{uuid}, $arguments) if $c->tx;
            }
        } elsif ($type =~ /^proposal_open_contract:/ and $m[0] eq $symbol) {
            BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement::send_proposal($c, $feed_channels_type->{$channel}->{uuid}, $arguments)
                if $c->tx;
        } elsif ($m[0] eq $symbol) {
            my $u = BOM::Market::Underlying->new($symbol);
            $message =~ /;$type:([.0-9+-]+),([.0-9+-]+),([.0-9+-]+),([.0-9+-]+);/;
            $c->send({
                    json => {
                        msg_type => 'ohlc',
                        echo_req => $arguments,
                        (exists $arguments->{req_id})
                        ? (req_id => $arguments->{req_id})
                        : (),
                        ohlc => {
                            id          => $feed_channels_type->{$channel}->{uuid},
                            epoch       => $m[1],
                            open_time   => $m[1] - $m[1] % $type,
                            symbol      => $symbol,
                            granularity => $type,
                            open        => $u->pipsized_value($1),
                            high        => $u->pipsized_value($2),
                            low         => $u->pipsized_value($3),
                            close       => $u->pipsized_value($4)}}}) if $c->tx;
        }
    }

    return;
}

sub _feed_channel {
    my ($c, $subs, $symbol, $type, $args) = @_;
    my $uuid;

    my $feed_channel      = $c->stash('feed_channel');
    my $feed_channel_type = $c->stash('feed_channel_type');

    my $redis = $c->stash('redis');
    if ($subs eq 'subscribe') {
        if (exists $feed_channel_type->{"$symbol;$type"}) {
            return;
        }
        $uuid = Data::UUID->new->create_str();
        $feed_channel->{$symbol} += 1;
        $feed_channel_type->{"$symbol;$type"}->{args} = $args;
        $feed_channel_type->{"$symbol;$type"}->{uuid} = $uuid;
        $redis->subscribe(["FEED::$symbol"], sub { });
    }

    if ($subs eq 'unsubscribe') {
        $feed_channel->{$symbol} -= 1;
        delete $feed_channel_type->{"$symbol;$type"};
        if ($feed_channel->{$symbol} <= 0) {
            $redis->unsubscribe(["FEED::$symbol"], sub { });
            delete $feed_channel->{$symbol};
        }
    }

    $c->stash('feed_channel'      => $feed_channel);
    $c->stash('feed_channel_type' => $feed_channel_type);

    return $uuid;
}

1;
