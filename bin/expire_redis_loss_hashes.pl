#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::CompanyLimits::SyncLoss;
use Data::Dumper;

my %output = BOM::CompanyLimits::SyncLoss::reset_daily_loss_hashes();

print 'Expire result (1 if timeout is set, 0 if key does not exist):', Dumper(\%output);



