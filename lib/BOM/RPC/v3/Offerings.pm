package BOM::RPC::v3::Offerings;

use strict;
use warnings;

use BOM::RPC::v3::Utility;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Platform::Context qw (localize request);
use BOM::Product::Finder qw(get_contracts_for);

sub contracts_for {
    my $params = shift;

    my $args         = $params->{args};
    my $symbol       = $args->{contracts_for};
    my $currency     = $args->{currency} || 'USD';
    my $product_type = $args->{product_type} // 'common';

    my $contracts_for = get_contracts_for({
        symbol       => $symbol,
        product_type => $product_type
    });

    my $i = 0;
    foreach my $contract (@{$contracts_for->{available}}) {
        if (exists $contract->{payout_limit}) {
            $contracts_for->{available}->[$i]->{payout_limit} = $contract->{payout_limit}->{$currency};
        }
        $i++;
    }

    if (not $contracts_for or $contracts_for->{hit_count} == 0) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidSymbol',
                message_to_client => BOM::Platform::Context::localize('The symbol is invalid.')});
    } else {
        $contracts_for->{'spot'} = create_underlying($symbol)->spot();
        return $contracts_for;
    }

    return;
}

1;
