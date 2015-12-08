package BOM::Database::Rose::DB::Cache;

use strict;
use warnings;

use parent 'Rose::DB::Cache';

sub finish_request_cycle {
    my $self = shift;

    foreach my $entry ($self->db_cache_entries) {
        my $db  = $entry->db;
        my $dbh = $db->dbh;

        $dbh->disconnect if $dbh;
    }
    $self->clear;

    return;
}

1;
