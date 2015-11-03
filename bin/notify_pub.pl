#!/usr/bin/perl
use strict;
use warnings;
use 5.010;
use YAML::XS;
use DBI;
use RedisDB;
use JSON;

my $conn = _master_db_connections();

my $forks = 0;
my @cpid;
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

        my $redis = _redis();
        my $dbh   = _db($ip);

        $dbh->do("LISTEN transaction_watchers");

        LISTENLOOP: {
            while (my $notify = $dbh->pg_notifies) {
                my ($name, $pid, $payload) = @$notify;
                my $msg = _msg($payload);
                _publish($redis, $msg);
            }
            sleep(1);
            redo;
        }
        exit;
    }
}

$SIG{INT} = sub {
    foreach my $p (@cpid) {
        say "Killing $p";
        kill KILL => $p;
    }
};

for (1 .. $forks) {
    my $pid = wait();
    say "Parent saw $pid exiting";
}

sub _publish {
    my $redis = shift;
    my $msg   = shift;

    my $expire_in = 2;

    return if $msg->{account_id} ne '12353508';
    $redis->set('TXNUPDATE::balance_' . $msg->{account_id}, JSON::to_json($msg));
    $redis->expire('TXNUPDATE::balance_' . $msg->{account_id},  $expire_in);
    $redis->set('TXNUPDATE::' . $msg->{action_type} . '_' . $msg->{account_id}, JSON::to_json($msg));
    $redis->expire('TXNUPDATE::' . $msg->{action_type} . '_' . $msg->{account_id},  $expire_in);
    $redis->set('TXNUPDATE::transaction_' . $msg->{account_id}, JSON::to_json($msg));
    $redis->expire('TXNUPDATE::transaction_' . $msg->{account_id},  $expire_in);
}

sub _msg {
    my $payload = shift;
    my @items = split(',', $payload);
    my $msg;

    $msg->{id}                      = $items[0];
    $msg->{account_id}              = $items[1];
    $msg->{action_type}             = $items[2];
    $msg->{referrer_type}           = $items[3];
    $msg->{financial_market_bet_id} = $items[4];
    $msg->{payment_id}              = $items[5];
    $msg->{amount}                  = $items[6];
    $msg->{balance_after}           = $items[7];
    return $msg;
}

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
        "dbi:Pg:dbname=regentmarkets;host=$ip;port=5432",
        'write',
        $conn->{$ip},
        {
            AutoCommit => 1,
            RaiseError => 1,
            PrintError => 1
        });
}

sub _redis {
    my $config = YAML::XS::LoadFile('/etc/rmg/chronicle.yml');
    return RedisDB->new(
        host     => $config->{write}->{host},
        port     => $config->{write}->{port},
        password => $config->{write}->{password});
}
