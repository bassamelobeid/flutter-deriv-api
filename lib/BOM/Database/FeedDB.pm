package BOM::Database::FeedDB;

use strict;
use warnings;

use YAML::XS;
use DBI;

my $config;
BEGIN {
  $config = YAML::XS::LoadFile('/etc/rmg/feeddb.yml');
}

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
    return DBI->connect_cached(
        "dbi:Pg:dbname=feed$db_postfix;port=5433;host=" . $config->{write}->{$ip},
        "write", $config->{password} )
      || die($DBI::errstr);
}

1;
