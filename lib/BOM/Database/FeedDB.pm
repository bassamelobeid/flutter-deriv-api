package BOM::Database::FeedDB;

use strict;
use warnings;

use YAML::XS;
use DBI;
use feature "state";

sub read_dbh {
    return DBI->connect_cached(
        "dbi:Pg:dbname=feed-replica;port=6433;host=/var/run/postgresql",
        "read", "" )
      || die($DBI::errstr);
}

sub write_dbh {
    state $config = YAML::XS::LoadFile('/etc/rmg/feeddb.yml');
    return DBI->connect_cached(
        "dbi:Pg:dbname=feed-write;port=6433;host=/var/run/postgresql",
        "write", "" )
      || die($DBI::errstr);
}

sub any_event_connection_str {
    state $config = YAML::XS::LoadFile('/etc/rmg/feeddb.yml');
    return
        'host=/var/run/postgresql port=6433 dbname=feed-write user=write';
}

1;
