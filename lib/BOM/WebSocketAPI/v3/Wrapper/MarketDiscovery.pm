package BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery;

use strict;
use warnings;

use JSON;
use Cache::RedisDB;

use BOM::WebSocketAPI::v3::MarketDiscovery;
use BOM::WebSocketAPI::v3::Wrapper::System;
use BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement;

sub trading_times {
    my ($c, $args) = @_;

    return {
        msg_type      => 'trading_times',
        trading_times => BOM::WebSocketAPI::v3::MarketDiscovery::trading_times($args),
    };
}

sub asset_index {
    my ($c, $args) = @_;

    my $language = $c->stash('request')->language;

    if (my $r = Cache::RedisDB->get("WS_ASSETINDEX", $language)) {
        return {
            msg_type    => 'asset_index',
            asset_index => JSON::from_json($r)};
    }

    my $response = BOM::WebSocketAPI::v3::MarketDiscovery::asset_index($language, $args);

    Cache::RedisDB->set("WS_ASSETINDEX", $language, JSON::to_json($response), 3600);

    return {
        msg_type    => 'asset_index',
        asset_index => $response
    };
}

sub ticks {
    my ($c, $args) = @_;

    my @symbols = (ref $args->{ticks}) ? @{$args->{ticks}} : ($args->{ticks});
    foreach my $symbol (@symbols) {
        my $response = BOM::WebSocketAPI::v3::MarketDiscovery::validate_offering($symbol);
        if ($response and exists $response->{error}) {
            return $c->new_error('ticks', $response->{error}->{code}, $response->{error}->{message_to_client});
        } else {
            if (exists $args->{subscribe} and $args->{subscribe} eq '0') {
                _feed_channel($c, 'unsubscribe', $symbol, 'tick');
            } else {
                my $uuid;
                if (not $uuid = _feed_channel($c, 'subscribe', $symbol, 'tick')) {
                    return $c->new_error('ticks', 'AlreadySubscribed', $c->l('You are already subscribed to [_1]', $symbol));
                }
            }
        }
    }
    return;
}

sub ticks_history {
    my ($c, $args) = @_;

    my $symbol   = $args->{ticks_history};
    my $response = BOM::WebSocketAPI::v3::MarketDiscovery::validate_symbol($symbol);
    if ($response and exists $response->{error}) {
        return $c->new_error('ticks_history', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        $response = BOM::WebSocketAPI::v3::MarketDiscovery::ticks_history($symbol, $args);
        if ($response and exists $response->{error}) {
            return $c->new_error('ticks_history', $response->{error}->{code}, $response->{error}->{message_to_client});
        } else {
            if (exists $args->{subscribe} and $args->{subscribe} eq '0') {
                _feed_channel($c, 'unsubscribe', $symbol, $response->{publish});
                return;
            } else {
                $response = BOM::WebSocketAPI::v3::MarketDiscovery::validate_license($symbol);
                if ($response and exists $response->{error}) {
                    return $c->new_error('ticks_history', $response->{error}->{code}, $response->{error}->{message_to_client});
                }
                if (not _feed_channel($c, 'subscribe', $symbol, $response->{publish})) {
                    return $c->new_error('ticks_history', 'AlreadySubscribed', $c->l('You are already subscribed to [_1]', $symbol));
                }
            }
            return {
                msg_type => $response->{type},
                %{$response->{data}}};
        }
    }
    return;
}

sub proposal {
    my ($c, $args) = @_;

    my $symbol   = $args->{symbol};
    my $response = BOM::WebSocketAPI::v3::MarketDiscovery::validate_symbol($symbol);
    if ($response and exists $response->{error}) {
        return $c->new_error('proposal', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        my $id = _feed_channel($c, 'subscribe', $symbol, 'proposal:' . JSON::to_json($args));
        send_ask($c, $id, $args);
    }
    return;
}

sub send_ask {
    my ($c, $id, $args) = @_;

    my %details  = %{$args};
    my $response = BOM::WebSocketAPI::v3::MarketDiscovery::get_ask(BOM::WebSocketAPI::v3::MarketDiscovery::prepare_ask(\%details));
    if ($response->{error}) {
        BOM::WebSocketAPI::v3::Wrapper::System::forget_one($c, $id);

        my $proposal = {id => $id};
        $proposal->{longcode}  = delete $response->{longcode}  if $response->{longcode};
        $proposal->{ask_price} = delete $response->{ask_price} if $response->{ask_price};
        $c->send({
                json => {
                    msg_type => 'proposal',
                    echo_req => $args,
                    proposal => $proposal,
                    %$response
                }});
    } else {
        $c->send({
                json => {
                    msg_type => 'proposal',
                    echo_req => $args,
                    proposal => {
                        id => $id,
                        %$response
                    }}});
    }
    return;
}

sub process_realtime_events {
    my ($c, $message) = @_;

    my @m = split(';', $message);
    my $feed_channels_type = $c->stash('feed_channel_type');

    foreach my $channel (keys %{$feed_channels_type}) {
        $channel =~ /(.*);(.*)/;
        my $symbol = $1;
        my $type   = $2;

        if ($type eq 'tick' and $m[0] eq $symbol) {
            $c->send({
                    json => {
                        msg_type => 'tick',
                        echo_req => $feed_channels_type->{$channel}->{args},
                        tick     => {
                            id     => $feed_channels_type->{$channel}->{uuid},
                            symbol => $symbol,
                            epoch  => $m[1],
                            quote  => BOM::Market::Underlying->new($symbol)->pipsized_value($m[2])}}}) if $c->tx;
        } elsif ($type =~ /^proposal:/ and $m[0] eq $symbol) {
            send_ask($c, $feed_channels_type->{$channel}->{uuid}, $feed_channels_type->{$channel}->{args}) if $c->tx;
        } elsif ($type =~ /^proposal_open_contract:/ and $m[0] eq $symbol) {
            BOM::WebSocketAPI::v3::Wrapper::PortfolioManagement::send_proposal(
                $c,
                $feed_channels_type->{$channel}->{uuid},
                $feed_channels_type->{$channel}->{args}) if $c->tx;
        } elsif ($m[0] eq $symbol) {
            my $u = BOM::Market::Underlying->new($symbol);
            $message =~ /;$type:([.0-9+-]+),([.0-9+-]+),([.0-9+-]+),([.0-9+-]+);/;
            $c->send({
                    json => {
                        msg_type => 'ohlc',
                        echo_req => $feed_channels_type->{$channel},
                        ohlc     => {
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
    my ($c, $subs, $symbol, $type) = @_;
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
        $feed_channel_type->{"$symbol;$type"}->{args} = $c->stash('args');
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
