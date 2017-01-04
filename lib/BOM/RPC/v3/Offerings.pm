package BOM::RPC::v3::Offerings;

use strict;
use warnings;

use BOM::RPC::v3::Utility;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Platform::Context qw (localize request);
use BOM::Product::Contract::Finder;
use BOM::Product::Contract::Finder::Japan;

sub contracts_for {
    my $params = shift;

    my $args            = $params->{args};
    my $symbol          = $args->{contracts_for};
    my $currency        = $args->{currency} || 'USD';
    my $product_type    = $args->{product_type} // 'basic';
    my $landing_company = $args->{landing_company} // 'costarica';

    my $contracts_for;
    my $query_args = {
        symbol          => $symbol,
        landing_company => $landing_company,
    };
    if ($product_type eq 'multi_barrier') {
        $contracts_for = BOM::Product::Contract::Finder::Japan::available_contracts_for_symbol($query_args);
    } else {
        $contracts_for = BOM::Product::Contract::Finder::available_contracts_for_symbol($query_args);
    }

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
