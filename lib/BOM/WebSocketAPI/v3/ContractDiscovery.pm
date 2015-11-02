package BOM::WebSocketAPI::v3::ContractDiscovery;

use strict;
use warnings;

use BOM::Product::Contract::Finder;
use BOM::Platform::Runtime::LandingCompany::Registry;
use BOM::Product::Contract::Finder::Japan;
use BOM::Platform::Context qw(localize);

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

sub contracts_for {
    my ($c, $args) = @_;
    my $symbol = $args->{contracts_for};
    my $region = $args->{region} || 'other';
    my $contracts_for;
    if ($region eq 'japan') {
        $contracts_for = BOM::Product::Contract::Finder::Japan::available_contracts_for_symbol({symbol => $symbol});
    } else {
        $contracts_for = BOM::Product::Contract::Finder::available_contracts_for_symbol({symbol => $symbol});
    }
    if ($contracts_for->{hit_count} == 0) {
        return $c->new_error('contracts_for', 'InvalidSymbol', localize('The symbol is invalid.'));
    } else {
        return {
            msg_type      => 'contracts_for',
            contracts_for => $contracts_for,
        };
    }
}

1;
