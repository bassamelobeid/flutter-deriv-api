package BOM::WebSocketAPI::v3::ContractDiscovery;

use strict;
use warnings;

use BOM::Platform::Runtime::LandingCompany::Registry;
use BOM::Platform::Context qw (localize);
use BOM::Product::Contract::Finder;
use BOM::Product::Contract::Finder::Japan;

sub payout_currencies {
    my $account = shift;

    my $currencies;
    if ($account) {
        $currencies = [$account->currency_code];
    } else {
        my $lc = BOM::Platform::Runtime::LandingCompany::Registry->new->get('costarica');
        $currencies = $lc->legal_allowed_currencies;
    }

    return $currencies,;
}

sub contracts_for {
    my $args = shift;

    my $symbol = $args->{contracts_for};
    my $contracts_for;
    if ($args->{region} and $args->{region} eq 'japan') {
        $contracts_for = BOM::Product::Contract::Finder::Japan::available_contracts_for_symbol({symbol => $symbol});
    } else {
        $contracts_for = BOM::Product::Contract::Finder::available_contracts_for_symbol({symbol => $symbol});
    }

    if (not $contracts_for or $contracts_for->{hit_count} == 0) {
        return BOM::WebSocketAPI::v3::Utility::create_error({
                code              => 'InvalidSymbol',
                message_to_client => BOM::Platform::Context::localize('The symbol is invalid.')});
    } else {
        $contracts_for->{'spot'} = BOM::Market::Underlying->new($symbol)->spot();
        return $contracts_for,;
    }

    return;
}

1;
