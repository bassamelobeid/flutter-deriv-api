package BOM::WebSocketAPI::v3::Wrapper::ContractDiscovery;

use strict;
use warnings;

use BOM::WebSocketAPI::v3::ContractDiscovery;

sub payout_currencies {
    my $c = shift;

    return {
        msg_type          => 'payout_currencies',
        payout_currencies => BOM::WebSocketAPI::v3::ContractDiscovery::payout_currencies($c->stash('account')),
    };
}

sub contracts_for {
    my ($c, $args) = @_;
    my $reponse = BOM::WebSocketAPI::v3::ContractDiscovery::contracts_for($args);
    if ($reponse->{error}) {
        return $c->new_error('contracts_for', $response->{error}->{code}, $response->{error}->{message_to_client});
    } else {
        return {
            msg_type      => 'contracts_for',
            contracts_for => $response
        };
    }
}

1;
