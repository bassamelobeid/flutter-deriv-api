package BOM::Database::FeedDB;

use strict;
use warnings;

use YAML::XS;
use DBI;

sub read_dbh {
  my $db_postfix = $ENV{DB_POSTFIX} // '';
    return DBI->connect_cached(
        "dbi:Pg:dbname=feed-replica$db_postfix;port=6433;host=/var/run/postgresql",
        "read", "", {pg_server_prepare => 0} )
      || die($DBI::errstr);
}

sub write_dbh {
    my $ip = 'ip';
    $ip = shift if @_;
    my $db_postfix = $ENV{DB_POSTFIX} // '';
    my $config;
    my $srvip;
    BEGIN {
      $config = YAML::XS::LoadFile('/etc/rmg/feeddb.yml');
      $srvip  = $config->{write}->{$ip};
    }
    return DBI->connect_cached(
        "dbi:Pg:dbname=feed$db_postfix;port=5433;host=" . $srvip,
        "write", $config->{password} )
      || die($DBI::errstr);
}

sub any_event_connection_str {
    my $db_postfix = $ENV{DB_POSTFIX} // '';
    return "host=/var/run/postgresql port=6433 dbname=feed-replica$db_postfix user=read";
}

1;
