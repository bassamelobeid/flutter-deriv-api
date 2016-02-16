package BOM::Database::FeedDB;

use strict;
use warnings;

use DBI;
use feature "state";

sub read_dbh {
    return DBI->connect_cached(
        "dbi:Pg:dbname=feed;port=6433;host=/var/run/postgresql",
        "read", '' )
      || die($DBI::errstr);
}

sub write_dbh {
    return DBI->connect_cached(
        "dbi:Pg:dbname=feed;port=6433;host=/var/run/postgresql",
        "write", '' )
      || die($DBI::errstr);
}

sub any_event_connection_str {
    return 'host=/var/run/postgresql port=6433 dbname=feed user=write';
}

1;
