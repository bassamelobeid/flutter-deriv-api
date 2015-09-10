package BOM::Product::Pricing::Engine::Utils;

use 5.010;
use strict;
use warnings;

sub default_probability_reference {
    my $err = shift;

    return {
        probability => 1,
        debug_info  => undef,
        markups     => {
            model_markup      => 0,
            commission_markup => 0,
            risk_markup       => 0,
        },
        error => $err,
    };
}

