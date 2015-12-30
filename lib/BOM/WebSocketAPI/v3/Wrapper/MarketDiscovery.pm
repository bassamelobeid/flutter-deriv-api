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

    my $client               = $c->stash('client');
    my $landing_company_name = 'costarica';
    if ($client) {
        $landing_company_name = $client->landing_company->short;
    }
    my $legal_allowed_markets = BOM::Platform::Runtime::LandingCompany::Registry->new->get($landing_company_name)->legal_allowed_markets;

    my $cache_key = join('::', $landing_company_name, $args->{active_symbols}, $c->stash('request')->language);
    my $result;
    return JSON::from_json($result) if $result = Cache::RedisDB->get("WS_ACTIVESYMBOL", $cache_key);

    BOM::WebSocketAPI::Websocket_v3::rpc(
        $c,
        'active_symbols',
        sub {
            my $response = shift;
            $result = {
                msg_type       => 'active_symbols',
                active_symbols => $response
            };
            Cache::RedisDB->set("WS_ACTIVESYMBOL", $cache_key, JSON::to_json($result), 300 - (time % 300));
            return $result;
        },
        {
            args           => $args,
            client_loginid => $c->stash('loginid')});
    return;
}

1;
