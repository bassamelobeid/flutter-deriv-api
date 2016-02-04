package BOM::Database::FeedDB;

use strict;
use warnings;

use YAML::XS;
use DBI;
use feature "state";

sub read_dbh {
    state $config = YAML::XS::LoadFile('/etc/rmg/feeddb.yml');
    return DBI->connect_cached(
        "dbi:Pg:dbname=feed;port=6433;host=" . $config->{replica}->{ip},
        "read", $config->{password} )
      || die($DBI::errstr);
}

sub write_dbh {
    state $config = YAML::XS::LoadFile('/etc/rmg/feeddb.yml');
    return DBI->connect_cached(
        "dbi:Pg:dbname=feed;port=6433;host=" . $config->{write}->{ip},
        "write", $config->{password} )
      || die($DBI::errstr);
}

sub any_event_connection_str {
    state $config = YAML::XS::LoadFile('/etc/rmg/feeddb.yml');
    return
        'host='
      . $config->{replica}->{ip}
      . ' port=6433 dbname=feed user=write password='
      . $config->{password};
}

1;
