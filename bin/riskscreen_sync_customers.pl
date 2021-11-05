#!/usr/bin/perl

use strict;
use warnings;
use feature qw(state);
no indirect;

=head1 NAME

C<riskscreen_sync_customers.pl>

=head1 DESCRIPTION

This scripts fetches new customers and matches from risk screen server and save a summary in B<userdb>.

=cut

use Syntax::Keyword::Try;
use Getopt::Long;
use Data::Dumper;
use Log::Any qw($log);

use Log::Any::Adapter qw(DERIV),
    stderr    => 'json',
    log_level => 'info';

use BOM::Platform::RiskScreenAPI;

GetOptions(
    'v|verbose' => \my $verbose,
);

try {
    my $result = BOM::Platform::RiskScreenAPI::sync_all_customers()->get;
    if ($verbose) {
        my $new_customer_count     = scalar $result->{new_customers}->@*;
        my $updated_customer_count = scalar $result->{updated_customers}->@*;
        my $last_update_date       = $result->{last_update_date};

        print "Number of new clients found: $new_customer_count \n";
        print "Clients updated with new matches: $updated_customer_count ";
        print "(Since $last_update_date) \n" if $last_update_date;
        print "\n";
    }
} catch ($e) {
    $log->error($e);
}
