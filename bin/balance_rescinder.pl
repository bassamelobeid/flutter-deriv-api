#!/etc/rmg/bin/perl

package main;
use strict;
use warnings;

use Getopt::Long;
use BOM::User::Script::BalanceRescinder;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $log_level = 'info';
GetOptions('l|log=s' => \$log_level);
Log::Any::Adapter->import(qw(Stderr), log_level => $log_level);

=head1 NAME

balance_rescinder.pl

=head1 DESCRIPTION

This is a CRON script that automatically rescinds the balance of disabled accounts. 

For more details look at L<BOM::User::Script::BalanceRescinder>.

=cut

BOM::User::Script::BalanceRescinder->new(broker_code => $_)->run for (qw/CR MX MLT MF DW/);
