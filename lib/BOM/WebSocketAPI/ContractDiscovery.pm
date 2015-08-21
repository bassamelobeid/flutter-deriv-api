package BOM::WebSocketAPI::ContractDiscovery;

use strict;
use warnings;

use BOM::Product::Contract::Finder;
use BOM::Platform::Runtime::LandingCompany::Registry;

sub payout_currencies {
    my $c = shift;

    my $currencies;
    if (my $account = $c->stash('account')) {
        $currencies = [$account->currency_code];
    } else {
        my $lc = BOM::Platform::Runtime::LandingCompany::Registry->new->get('costarica');
        $currencies = $lc->legal_allowed_currencies;
    }

    return {
        msg_type          => 'payout_currencies',
        payout_currencies => $currencies,
    };
}

sub available_contracts_for_symbol {
    my ($c, $args) = @_;

    return {
        msg_type      => 'contracts_for',
        contracts_for => BOM::Product::Contract::Finder::available_contracts_for_symbol($args->{contracts_for}),
    };
}

1;
