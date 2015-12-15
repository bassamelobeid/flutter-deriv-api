package BOM::Database::Rose::DB::Cache;

use strict;
use warnings;

use parent 'Rose::DB::Cache';

sub finish_request_cycle {
    my $self = shift;

    foreach my $entry ($self->db_cache_entries) {
        my $db  = $entry->db;
        my $dbh = $db->dbh;

        # This closes connections to writable databases
        # For such, pgbouncer works in session mode. So,
        # closing them is essential. Read-only databases
        # work in transaction mode and can hence kept open.
        # See /etc/init.d/binary_pgbouncer
        if ($dbh and not $db->database =~ /replica/) {
            $dbh->disconnect;
            $db->dbh(undef);
        }
    }

    return;
}

1;
