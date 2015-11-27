package BOM::Database::Rose::DB::Cache;

use strict;
use warnings;

use parent 'Rose::DB::Cache';
use Try::Tiny;

sub finish_request_cycle {
    my $self = shift;

    foreach my $entry ($self->db_cache_entries) {
        my $db = $entry->db;
        my $dbh;

        try {
            $dbh = $db->dbh;
            $dbh->rollback unless $dbh->{AutoCommit};
            $dbh->do('DISCARD ALL');
        }
        catch {
            $dbh->disconnect if $dbh;
            $db->dbh(undef);
        };
    }

    return;
}

1;
