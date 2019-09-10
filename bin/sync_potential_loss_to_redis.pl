#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::CompanyLimits::SyncLoss;
use LandingCompany::Registry;

foreach my $lc (LandingCompany::Registry::all()) {
    my $landing_company = $lc->{short};
    foreach my $broker_code (@{$lc->{broker_codes}}) {
        my $output = BOM::CompanyLimits::SyncLoss::sync_potential_loss_to_redis($broker_code, $landing_company);
        $output = $output->[1] if ref $output eq 'ARRAY';
        print "Update potential loss from $broker_code clientdb ($landing_company)... Result: $output\n";
    }
}

