#!/usr/bin/env perl

use strict;
use warnings;

use Getopt::Long;
use Log::Any::Adapter;
use BOM::User::Script::P2PDailyMaintenance;

=head1 Name

p2p_daily_maintenance - P2P housekpeeing script to be run by daily cron

=cut

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $log_level = 'info';
GetOptions('l|log=s' => \$log_level);
Log::Any::Adapter->import(qw(Stderr), log_level => $log_level);

exit BOM::User::Script::P2PDailyMaintenance->new->run;
