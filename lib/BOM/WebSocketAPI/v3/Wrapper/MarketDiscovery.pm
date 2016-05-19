package BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery;

use strict;
use warnings;

use JSON;
use Cache::RedisDB;

use BOM::WebSocketAPI::Websocket_v3;

sub asset_index_cached {
    my ($c, $args, $params) = @_;

    my $language = $c->stash('language');
    if (my $r = Cache::RedisDB->get("WS_ASSETINDEX", $language)) {
        return {
            msg_type    => 'asset_index',
            asset_index => JSON::from_json($r)};
    }
    return;
}

sub cache_asset_index {
    my ($c, $args, $rpc_response) = @_;

    my $language = $c->stash('language');
    Cache::RedisDB->set("WS_ASSETINDEX", $language, JSON::to_json($rpc_response), 3600);
    return;
}

1;
