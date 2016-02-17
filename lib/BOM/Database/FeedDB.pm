package BOM::Database::FeedDB;

use strict;
use warnings;

use DBI;

sub read_dbh {
    return DBI->connect_cached(
        "dbi:Pg:dbname=feed-replica;port=6433;host=/var/run/postgresql",
        "read", '' )
      || die($DBI::errstr);
}

sub write_dbh {
    return DBI->connect_cached(
        "dbi:Pg:dbname=feed-write;port=6433;host=/var/run/postgresql",
        "write", '' )
      || die($DBI::errstr);
}

sub any_event_connection_str {
    return 'host=/var/run/postgresql port=6433 dbname=feed-write user=write';
}

1;
