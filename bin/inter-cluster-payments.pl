#!/usr/bin/perl
use strict;
use warnings;
use 5.010;
use YAML::XS;
use DBI;
use DBD::Pg;
use IO::Select;
use Try::Tiny;
use RedisDB;
use JSON;

sub _master_db_connections {
    my $config = YAML::XS::LoadFile('/etc/rmg/clientdb.yml');
    my $conn;
    foreach my $lc (keys %{$config}) {
        if (ref $config->{$lc}) {
            $conn->{$config->{$lc}->{write}->{ip}} = $config->{password};
        }
    }
    return $conn;
}

sub _db {
    my $ip = shift;
    DBI->connect(
        "dbi:Pg:dbname=regentmarkets;host=$ip;port=5432;application_name=notify_pub",
        'write',
        $conn->{$ip},
        {
            AutoCommit => 1,
            RaiseError => 1,
            PrintError => 0
        });
}

sub handle_queue {
    my $dbh = shift;

    my $peek_q = $dbh->prepare_cached(<<'SQL');
SELECT * FROM payment.inter_cluster_transfer_queue ORDER BY payment_id LIMIT 10
SQL

    my $rows;
    while ($peek_q->execute and
           $rows = $peek_q->fetchall_arrayref({}) and
           @$rows) {
    }
}

my $conn = _master_db_connections();

my $forks = 0;
my @cpid;
$SIG{INT} = sub {
    foreach my $p (@cpid) {
        say "Killing $p";
        kill KILL => $p;
    }
};

foreach my $ip (keys %{$conn}) {
    my $pid = fork;
    if (not defined $pid) {
        die 'Could not fork';
    }
    if ($pid) {
        $forks++;
        push @cpid, $pid;
    } else {
        say "starting to listen to $ip";

        while (1) {
            try {
                my $redis = _redis();
                my $dbh   = _db($ip);

                $dbh->do("LISTEN inter_cluster_transfer_queue");

                my $sel = IO::Select->new;
                $sel->add($dbh->{pg_socket});
                while ($sel->can_read()) {
                    handle_queue $dbh;
                    1 while $dbh->pg_notifies;
                }
            }
            catch {
                warn "$0 ($$): saw exception: $_";
                sleep 1;
            };
        }
        exit;
    }
}

for (1 .. $forks) {
    my $pid = wait();
    say "Parent saw $pid exiting";
}

