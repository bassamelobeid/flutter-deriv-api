#!/etc/rmg/bin/perl

package main;
use strict;
use warnings;

use Getopt::Long;
use BOM::User::Script::BalanceRescinder;
use LandingCompany::Registry;
use Log::Any::Adapter;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $log_level = 'info';
GetOptions('l|log=s' => \$log_level);
Log::Any::Adapter->import(
    qw(DERIV),
    log_level => $log_level,
);

=head1 NAME

balance_rescinder.pl

=head1 DESCRIPTION

This is a CRON script that automatically rescinds the balance of disabled accounts. 

For more details look at L<BOM::User::Script::BalanceRescinder>.

=cut

my $registry = LandingCompany::Registry->new;

my @broker_codes = $registry->all_real_broker_codes();

for my $broker_code (@broker_codes) {
    my $script = BOM::User::Script::BalanceRescinder->new(broker_code => $broker_code);
    $script->run;
}
