package BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery;

use strict;
use warnings;

use JSON;
use Cache::RedisDB;

use BOM::WebSocketAPI::Websocket_v3;
use BOM::Platform::Runtime::LandingCompany::Registry;

sub trading_times {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'trading_times',
        sub {
            my $response = shift;
            return {
                msg_type      => 'trading_times',
                trading_times => $response
            };
        },
        {args => $args});

    return;
}

sub asset_index {
    my ($c, $args) = @_;

    my $language = $c->stash('request')->language;
    if (my $r = Cache::RedisDB->get("WS_ASSETINDEX", $language)) {
        return {
            msg_type    => 'asset_index',
            asset_index => JSON::from_json($r)};
    }

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'asset_index',
        sub {
            my $response = shift;
            Cache::RedisDB->set("WS_ASSETINDEX", $language, JSON::to_json($response), 3600);
            return {
                msg_type    => 'asset_index',
                asset_index => $response
            };
        },
        {
            args     => $args,
            language => $language
        });

    return;
}

sub active_symbols {
    my ($c, $args) = @_;

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'active_symbols',
        sub {
            my $response = shift;
            return {
                msg_type       => 'active_symbols',
                active_symbols => $response
            };
        },
        {
            args  => $args,
            token => $c->stash('token')});
    return;
}

1;
