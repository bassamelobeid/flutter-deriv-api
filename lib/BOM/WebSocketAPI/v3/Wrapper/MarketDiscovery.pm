package BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery;

use strict;
use warnings;

use JSON;
use Cache::RedisDB;

use BOM::WebSocketAPI::Websocket_v3;

sub asset_index {
    my ($c, $args) = @_;

    my $language = $c->stash('language');
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

1;
