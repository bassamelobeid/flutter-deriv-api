package BOM::Database::FeedDB;

use strict;
use warnings;

use YAML::XS;
use DBI;
use feature "state";

sub read_dbh {
    return DBI->connect_cached(
        "dbi:Pg:dbname=feed-replica;port=6433;host=/var/run/postgresql",
        "read", "", {pg_server_prepare => 0} )
      || die($DBI::errstr);
}

sub write_dbh {
    state $config = YAML::XS::LoadFile('/etc/rmg/feeddb.yml');
    return DBI->connect_cached(
        "dbi:Pg:dbname=feed;port=5433;host=" . $config->{write}->{ip},
        "write", $config->{password} )
      || die($DBI::errstr);
}

sub any_event_connection_str {
    state $config = YAML::XS::LoadFile('/etc/rmg/feeddb.yml');
    return 'host=/var/run/postgresql port=6433 dbname=feed-replica user=read';
}

1;
