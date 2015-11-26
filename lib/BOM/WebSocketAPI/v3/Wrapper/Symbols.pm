package BOM::WebSocketAPI::v3::Wrapper::Symbols;

use strict;
use warnings;

use BOM::WebSocketAPI::v3::Symbols;

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
        active_symbols => BOM::WebSocketAPI::v3::Symbols::active_symbols($client, $args)};
    Cache::RedisDB->set("WS_ACTIVESYMBOL", $cache_key, JSON::to_json($result), 300 - (time % 300));

    return $result;
}

1;
