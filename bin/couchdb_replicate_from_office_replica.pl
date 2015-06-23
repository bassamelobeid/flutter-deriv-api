#!/usr/bin/perl

use strict;
use warnings;
use 5.010;

use BOM::Platform::Runtime;
use Carp;
use File::Basename;
use Getopt::Long;
use Pod::Usage;

my ($help, $no_destroy);
GetOptions(
    'help|h'       => \$help,
    'no-destroy|n' => \$no_destroy
) or pod2usage(2);

my ($action, $databases) = @ARGV;

pod2usage(2) if $help or not $action;

my @dbs;
if ($databases) {
    @dbs = split ',', $databases;
} else {
    @dbs = values %{BOM::Platform::Runtime->instance->datasources->couchdb_databases};
}
my $databases_option = '--dbs=' . join(',', @dbs);

my $couch_maintenance = dirname(__FILE__) . '/../../platform/bin/bom_couchdb_maintenance.pm';
my $office_feed       = '\'https://couchdb:7%U4l$ogFl@office-feed.regentmarkets.com:6984/\'';

if ($action eq 'start') {
    unless ($no_destroy) {
        my $dbs = join(',', @dbs);
        say "Deleting couch databases: $dbs";
        local $ENV{FORCEDESTROY} = 1;
        system($couch_maintenance. " --destroy-databases='$dbs'") == 0 or confess 'Failed to destroy database';
    }

    local $ENV{FORCEONMASTER} = 1;
    `$couch_maintenance --master-server=$office_feed --start-replication $databases_option`;
} elsif ($action eq 'stop') {
    local $ENV{FORCEONMASTER} = 1;
    `$couch_maintenance --master-server=$office_feed --stop-replication $databases_option`;
} elsif ($action eq 'restart') {
    local $ENV{FORCEONMASTER} = 1;
    # Assume no destroy.
    `$couch_maintenance --master-server=$office_feed --stop-replication $databases_option`;
    # If you restart too quickly, it just keeps the old stale one.
    sleep 3;
    `$couch_maintenance --master-server=$office_feed --start-replication $databases_option`;
} else {
    print "Unknown command\n";
}

__END__

=head1 NAME

couchdb_replicate_from_office_replica.pl -- start/stop local couchdb replication from office master couchdb

=head1 SYNOPSIS

couchdb_replicate_from_office_replica.pl [-h] [start|stop] [comma seperated list of databases]

Options:

  -h, --help           print this help message
  -n, --no-destroy     doesn't delete the databases before starting replication

=cut
