package BOM::Pricing::ContractsForGenerator;

use strict;
use warnings;

use BOM::Product::Contract::Finder::Japan;
use BOM::Product::Contract::Finder;

sub contracts_for {
    my $args = shift;

    my $product_type = delete $args->{product_type};
    my $contracts_for;

    if ($product_type eq 'multi_barrier') {
        $contracts_for = BOM::Product::Contract::Finder::Japan::available_contracts_for_symbol($args);
    } else {
        $contracts_for = BOM::Product::Contract::Finder::available_contracts_for_symbol($args);
        # this is temporary solution till the time front apps are fixed
        # filter CALLE|PUTE only for non japan
        $contracts_for->{available} = [grep { $_->{contract_type} !~ /^(?:CALLE|PUTE)$/ } @{$contracts_for->{available}}]
            if ($contracts_for and $contracts_for->{hit_count} > 0);
    }

    $contracts_for->{$_} += 0 for qw/open close/;    # make it integer in json encoding

    return {
        _generated => time,
        value      => $contracts_for
    };
}

1;
