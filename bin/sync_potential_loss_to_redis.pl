#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::CompanyLimits;
use BOM::CompanyLimits::SyncLoss;

foreach my $lc (BOM::CompanyLimits::get_supported_landing_companies()) {
    my $landing_company = $lc->{short};
    # Assume one-to-one correlation between broker code and landing company
    my $broker_code = $lc->{broker_codes}[0];
    my $output = BOM::CompanyLimits::SyncLoss::sync_potential_loss_to_redis($broker_code, $landing_company);
    print "Update potential loss from $broker_code clientdb ($landing_company)... Result: $output\n";
}

