package Binary::WebSocketAPI::v3::Wrapper::MarketDiscovery;

use strict;
use warnings;

use JSON;
use Cache::RedisDB;

sub asset_index_cached {
    my ($c, $req_storage) = @_;

    my $language = $c->stash('language');
    if (my $r = Cache::RedisDB->get("WS_ASSETINDEX", $language)) {
        return {
            msg_type    => 'asset_index',
            asset_index => JSON::from_json($r)};
    }
    return;
}

sub cache_asset_index {
    my ($c, $rpc_response) = @_;

    my $language = $c->stash('language');
    Cache::RedisDB->set("WS_ASSETINDEX", $language, JSON::to_json($rpc_response), 3600);
    return;
}

sub asset_index {
   my ($c, $req_storage) = @_;

    my $args = $req_storage->{args};
    $c->call_rpc({
            url         => Binary::WebSocketAPI::Hooks::get_pricing_rpc_url($c),
            args        => $args,
            method      => 'asset_index',
            msg_type    => 'asset_index',
            call_params => {
                language              => $c->stash('language'),
                landing_company       => $c->landing_company_name,
            },
            response => sub {
                my ($rpc_response, $api_response, $req_storage) = @_;
                return $api_response;
            },
        });
    return;
}

sub trading_times {
   my ($c, $req_storage) = @_;

    my $args = $req_storage->{args};
    $c->call_rpc({
            url         => Binary::WebSocketAPI::Hooks::get_pricing_rpc_url($c),
            args        => $args,
            method      => 'trading_times',
            msg_type    => 'trading_times',
            call_params => {
                language              => $c->stash('language'),
                landing_company       => $c->landing_company_name,
            },
            response => sub {
                my ($rpc_response, $api_response, $req_storage) = @_;
                return $api_response;
            },
        });
    return;
}

sub contracts_for {
   my ($c, $req_storage) = @_;

    my $args = $req_storage->{args};
    $c->call_rpc({
            url         => Binary::WebSocketAPI::Hooks::get_pricing_rpc_url($c),
            args        => $args,
            method      => 'contracts_for',
            msg_type    => 'contracts_for',
            call_params => {
                language              => $c->stash('language'),
                landing_company       => $c->landing_company_name,
            },
            response => sub {
                my ($rpc_response, $api_response, $req_storage) = @_;
                return $api_response;
            },
        });
    return;
}
1;
