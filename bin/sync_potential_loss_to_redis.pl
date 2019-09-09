#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::CompanyLimits::SyncLoss;

foreach my $lc (['CR', 'svg'], ['MF', 'maltainvest'], ['MX', 'iom'], ['MLT', 'malta']) {
    my ($broker_code, $landing_company) = @$lc;
    my $output = BOM::CompanyLimits::SyncLoss::sync_potential_loss_to_redis($broker_code, $landing_company);
    print "Update potential loss from $broker_code clientdb ($landing_company)... Result: $output\n";
}

