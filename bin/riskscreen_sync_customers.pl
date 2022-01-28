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
use Log::Any qw($log);
use Log::Any::Adapter;
use Data::Dumper;

use BOM::Platform::RiskScreenAPI;

GetOptions(
    'l|log_level=s' => \my $log_level,
    'a|update_all'  => \my $update_all,
    'c|count=i'     => \my $count
);
Log::Any::Adapter->import(
    'DERIV',
    stderr    => 'text',
    log_level => $log_level // 'info'
);

$update_all //= 0;

$log->debugf('Starting to sync riskscreen data with UPDATE ALL = %d, LOG LEVEL = %s, count = %d', $update_all, $log_level, $count // '<undef>');

try {
    my $riskscreen_api = BOM::Platform::RiskScreenAPI->new(
        update_all => $update_all,
        count      => $count
    );
    $riskscreen_api->sync_all_customers($update_all, $count)->get;
} catch ($e) {
    warn Dumper $e;
}

