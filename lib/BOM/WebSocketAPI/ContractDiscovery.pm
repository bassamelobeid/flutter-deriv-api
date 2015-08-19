package BOM::WebSocketAPI::ContractDiscovery;

use strict;
use warnings;
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
    return $currencies;
}

1;
