#!/etc/rmg/bin/perl

use strict;
use warnings;

use Log::Any qw($log);
use Data::Dumper;
use BOM::CompanyLimits::SyncLoss;
use Log::Any::Adapter qw(Stdout), log_level => 'info';

my $output = BOM::CompanyLimits::SyncLoss::reset_daily_loss_hashes();

$log->info('Expire result (1 if timeout is set, 0 if key does not exist):', Dumper($output));



