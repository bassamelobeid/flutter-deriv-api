package Binary::WebSocketAPI::v3::Wrapper::MarketDiscovery;

use strict;
use warnings;

sub asset_index {
    my ($c, $req_storage) = @_;

    my $args = $req_storage->{args};
    $c->call_rpc({
            url         => Binary::WebSocketAPI::Hooks::get_pricing_rpc_url($c),
            args        => $args,
            method      => 'asset_index',
            msg_type    => 'asset_index',
            call_params => {
                language        => $c->stash('language'),
                landing_company => $c->landing_company_name,
            },
            response => sub {
                # @_ is ($rpc_response, $api_response, $req_storage)
                return $_[1];
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
                language        => $c->stash('language'),
                landing_company => $c->landing_company_name,
            },
            response => sub {
                # @_ is ($rpc_response, $api_response, $req_storage)
                return $_[1];
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
                language        => $c->stash('language'),
                landing_company => $c->landing_company_name,
            },
            response => sub {
                # @_ is ($rpc_response, $api_response, $req_storage)
                return $_[1];
            },
        });
    return;
}
1;
