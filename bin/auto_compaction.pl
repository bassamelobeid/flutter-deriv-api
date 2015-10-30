#!/usr/bin/perl

use 5.010;
use strict;
use warnings;
use Carp;
use BOM::Platform::Runtime;

if (BOM::Platform::Runtime->instance->hosts->localhost->canonical_name eq 'office-feed') {
    #Run only on Sunday's
    if ((localtime(time))[6] == 0) {
        _destroy_and_replicate();
    }
} else {
    system("/home/git/regentmarkets/bom-platform/bin/bom_couchdb_maintenance.pm --compact --keep-revisions=50");
}

sub _destroy_and_replicate {
    my $dbs = BOM::Platform::Runtime->instance->datasources->couchdb_databases;
    $dbs = join(',', values %{$dbs});
    local $ENV{FORCEDESTROY} = 1;
    system("/home/git/regentmarkets/bom-platform/bin/bom_couchdb_maintenance.pm --destroy-databases='$dbs'") == 0 or confess 'Failed to destroy database';
    system("/home/git/regentmarkets/bom-platform/bin/bom_couchdb_maintenance.pm --start-replication") == 0        or confess 'Failed to start replication';
    return;
}
