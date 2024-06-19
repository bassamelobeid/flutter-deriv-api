#!/usr/bin/perl

use strict;
use warnings;

=head1 NAME

ctrader_set_new_partner_id.pl | This script is used to set new partner ID on cTrader for our affiliates that has recently sign up for IB commission plan.

=head1 SYNOPSIS

./ctrader_set_new_partner_id.pl

=head1 OPTIONS

=over 20

=item B<-h>, B<--help>

Brief help message

=item B<-d>, B<--date>

Process IB accounts based on the created_at date. [Format: 2023-03-16]
If --date parameter is not supplied, the script will process IB accounts created the previous day

=item B<-a>, B<--all>

It forces script to fetch all IBs we have on affiliate.affiliate and process them
This option override --date option.

=back

=cut

use BOM::CTrader::Script::CtraderSetPartnerId;
use Getopt::Long;
use Log::Any qw($log);
use Log::Any::Adapter qw(Stderr), log_level => $ENV{BOM_LOG_LEVEL} // 'info';
use Pod::Usage;

my ($help, $date, $all);

GetOptions(
    'h|help!'  => \$help,
    'd|date=s' => \$date,
    'a|all!'   => \$all,
);

pod2usage(1) if $help;

# Trigger the script
my $ctrader_set_partnerid = BOM::CTrader::Script::CtraderSetPartnerId->new(
    date => $date,
    all  => $all,
);
$ctrader_set_partnerid->start->get;
