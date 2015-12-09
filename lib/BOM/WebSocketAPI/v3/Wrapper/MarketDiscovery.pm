package BOM::WebSocketAPI::v3::Wrapper::MarketDiscovery;

use strict;
use warnings;

use JSON;
use Cache::RedisDB;

use BOM::WebSocketAPI::v3::MarketDiscovery;
use BOM::Platform::Runtime::LandingCompany::Registry;

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

    $result = {
        msg_type => 'active_symbols',
        active_symbols => BOM::WebSocketAPI::v3::MarketDiscovery::active_symbols($client, $args)};
    Cache::RedisDB->set("WS_ACTIVESYMBOL", $cache_key, JSON::to_json($result), 300 - (time % 300));

    return $result;
}

1;
