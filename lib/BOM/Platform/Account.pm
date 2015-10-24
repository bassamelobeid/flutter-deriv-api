package BOM::Platform::Account;

use strict;
use warnings;

use BOM::Platform::Runtime;

sub get_real_acc_opening_type {
    my $args = shift;
    my ($residence, $from_client) = @{$args}{'residence', 'from_client'};

    my $gaming_company    = BOM::Platform::Runtime->instance->gaming_company_for_country($residence);
    my $financial_company = BOM::Platform::Runtime->instance->financial_company_for_country($residence);

    if ($from_client->is_virtual) {
        if ($gaming_company) {
            return $gaming_company if ($gaming_company eq 'japan');
            return 'real';
        } elsif ($financial_company) {
            # Eg: Germany
            return $financial_company if ($financial_company eq 'maltainvest');
            # Eg: Singapore has no gaming_company
            return 'real';
        }
    } else {
        # MLT upgrade to MF
        return $financial_company if ($financial_company eq 'maltainvest');
    }
    return;
}

1;
