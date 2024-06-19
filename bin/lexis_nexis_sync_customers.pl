#!/usr/bin/perl

use strict;
use warnings;
use feature qw(state);
no indirect;

=head1 NAME

C<lexis_nexis_sync_customers.pl>

=head1 DESCRIPTION

This scripts fetches new customers and matches from lexis nexis server and save a summary in B<userdb>.

=cut

use Syntax::Keyword::Try;
use Getopt::Long;
use Log::Any qw($log);
use Log::Any::Adapter;
use Data::Dumper;

use BOM::Platform::LexisNexisAPI;

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
    my $lexis_nexis_api = BOM::Platform::LexisNexisAPI->new(
        update_all => $update_all,
        count      => $count // 0
    );

    $lexis_nexis_api->sync_all_customers($update_all, $count)->get;

} catch ($e) {
    warn Dumper $e;
}

