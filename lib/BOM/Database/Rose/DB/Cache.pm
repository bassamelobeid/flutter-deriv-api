package BOM::Database::Rose::DB::Cache;

use strict;
use warnings;
use Syntax::Keyword::Try;

use parent 'Rose::DB::Cache';

sub finish_request_cycle {
    my $self = shift;

    foreach my $entry ($self->db_cache_entries) {
        my $db = $entry->db;
        next unless $db->has_dbh;

        my $dbh = $db->dbh;

        # This closes connections to writable databases
        # For such, pgbouncer works in session mode. So,
        # closing them is essential. Read-only databases
        # work in transaction mode and can hence kept open.
        # See /etc/init.d/binary_pgbouncer
        if ($dbh and not $db->database =~ /replica/) {
            $db->dbh(undef);
            try {
                $dbh->disconnect;
            } catch ($e) {
                warn __PACKAGE__ . ": while disconnecting from database: $e";
            }
        }
    }

    return;
}

1;
