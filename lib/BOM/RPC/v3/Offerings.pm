package BOM::RPC::v3::Offerings;

use strict;
use warnings;

use BOM::RPC::v3::Utility;
use BOM::Market::Underlying;
use BOM::Platform::Context qw (localize request);
use BOM::Product::Contract::Finder;
use BOM::Product::Contract::Finder::Japan;

sub contracts_for {
    my $params = shift;

    my $args   = $params->{args};
    my $symbol = $args->{contracts_for};
    my $contracts_for;
    if ($args->{region} and $args->{region} eq 'japan') {
        $contracts_for = BOM::Product::Contract::Finder::Japan::available_contracts_for_symbol({symbol => $symbol});
    } else {
        $contracts_for = BOM::Product::Contract::Finder::available_contracts_for_symbol({symbol => $symbol});
    }

    if (not $contracts_for or $contracts_for->{hit_count} == 0) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidSymbol',
                message_to_client => BOM::Platform::Context::localize('The symbol is invalid.')});
    } else {
        $contracts_for->{'spot'} = BOM::Market::Underlying->new($symbol)->spot();
        return $contracts_for,;
    }

    return;
}

1;
