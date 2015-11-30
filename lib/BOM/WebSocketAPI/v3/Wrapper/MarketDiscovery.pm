package BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery;

use strict;
use warnings;

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
            echo_req    => $args,
            msg_type    => 'asset_index',
            asset_index => JSON::from_json($r)};
    }

    my $response = BOM::WebSocketAPI::v3::MarketDiscovery::asset_index($language, $args);

    Cache::RedisDB->set("WS_ASSETINDEX", $language, JSON::to_json($response), 3600);

    return {
        echo_req    => $args,
        msg_type    => 'asset_index',
        asset_index => $response
    };
}

1;
