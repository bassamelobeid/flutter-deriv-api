package BOM::Platform::Script::NotifyPub;

use strict;
use warnings;
use 5.010;
use YAML::XS;
use DBI;
use DBD::Pg;
use IO::Select;
use Try::Tiny;
use RedisDB;
use JSON::MaybeXS;

my $conn;

sub run {
    $conn = _master_db_connections();

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

            while (1) {
                try {
                    my $redis = _redis();
                    my $dbh   = _db($ip);

                    $dbh->do("LISTEN transaction_watchers");

                    my $sel = IO::Select->new;
                    $sel->add($dbh->{pg_socket});
                    while ($sel->can_read) {
                        while (my $notify = $dbh->pg_notifies) {
                            my ($name, $pid, $payload) = @$notify;
                            _publish($redis, _msg($payload));
                        }
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

    local $SIG{INT} = sub {
        foreach my $p (@cpid) {
            say "Killing $p";
            kill KILL => $p;
        }
    };

    local $SIG{TERM} = $SIG{INT};

    for (1 .. $forks) {
        my $pid = wait();
        say "Parent saw $pid exiting";
    }
    return 0;
}

my $json = JSON::MaybeXS->new;

sub _publish {
    my $redis       = shift;
    my $msg         = shift;
    my $encoded_msg = $json->encode($msg);

    return $redis->publish('TXNUPDATE::transaction_' . $msg->{account_id}, $encoded_msg);
}

sub _msg {
    my $payload = shift;

    my %msg;
    @msg{
        qw/id account_id action_type referrer_type financial_market_bet_id
            payment_id amount balance_after transaction_time short_code currency_code purchase_time purchase_price sell_time payment_remark/
    } = split(',', $payload, 15);

    return \%msg;
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
    my $db_postfix = $ENV{DB_POSTFIX} // '';
    return DBI->connect(
        "dbi:Pg:dbname=regentmarkets$db_postfix;host=$ip;port=5432;application_name=notify_pub;sslmode=require",
        'write',
        $conn->{$ip},
        {
            AutoCommit => 1,
            RaiseError => 1,
            PrintError => 0
        });
}

sub _redis {
    my $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/chronicle.yml');
    return RedisDB->new(
        host     => $config->{write}->{host},
        port     => $config->{write}->{port},
        password => $config->{write}->{password});
}

1;
