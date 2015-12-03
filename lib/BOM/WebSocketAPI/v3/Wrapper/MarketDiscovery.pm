package BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery;

use strict;
use warnings;

use JSON;
use Cache::RedisDB;

use BOM::WebSocketAPI::v3::MarketDiscovery;

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
        my $response = BOM::WebSocketAPI::v3::MarketDiscovery::validate_underlying($symbol);
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
