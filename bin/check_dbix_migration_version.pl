#!/usr/bin/env perl

## Make sure all the clientdbs have the same dbix_migration value
## Silent on success, otherwise prints a report
## Expects to run as cron via the pgadmin user

use strict;
use warnings;
use DBI;

my @host = (qw/ cr vr mf mlt mx /);

my $COM      = 'SELECT value FROM dbix_migration';
my $oldvalue = '';
my $mismatch = 0;
my %val;
for my $host (@host) {
    my $dbh     = DBI->connect("dbi:Pg:service=${host}01", '', '');
    my $info    = $dbh->selectall_arrayref($COM);
    my $numrows = @$info;
    if ($numrows != 1) {
        print "Returned unexpected number of rows in dbix_migration from $host: $numrows\n";
        exit 1;
    }
    if ($info->[0][0] !~ /^(\d+)\s*$/) {
        print "Did not return a numeric value from dbix_migration.value for $host; got >>$info->[0][0]<<\n";
        exit 1;
    }
    my $value = $1;
    if ($oldvalue and $oldvalue != $value) {
        $mismatch = 1;
    }
    $oldvalue = $value;
    $val{$host} = $1;
}

exit 0 if !$mismatch;

print "Found different numbers for dbix_migration.value:\n";
for my $host (@host) {
    printf "%-3s: %d\n", uc $host, $val{$host};
}
exit 2;
