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
use JSON::MaybeUTF8 qw(:v1);

my $conn;

sub run {
    $conn = _master_db_connections();
    my $forks = 0;
    my @cpid;
    foreach my $addr (keys %{$conn}) {
        my $pid = fork;
        if (not defined $pid) {
            die 'Could not fork';
        }
        if ($pid) {
            $forks++;
            push @cpid, $pid;
        } else {
            say "starting to listen to $addr";

            while (1) {
                try {
                    my $redis = _redis();
                    my $dbh   = _db($conn->{$addr});

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

sub _publish {
    my $redis       = shift;
    my $msg         = shift;
    my $encoded_msg = encode_json_utf8($msg);

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
            my $data = $config->{$lc}->{write};
            my $port;

            if ($ENV{DB_TEST_PORT}) {
                # Unit test env, specific only to QA:
                $port = $ENV{DB_TEST_PORT};
                $data->{dbname} = 'cr';
            }

            $data->{dbname}   //= 'regentmarkets';
            $data->{password} //= $config->{password};
            # conn contains a hash ref which contains conection details needed per database
            $conn->{$data->{ip} . '/' . $data->{dbname}} = {
                ip       => $data->{ip},
                dbname   => $data->{dbname},
                password => $data->{password},
                port     => $port // 5432,
            };
        }
    }
    return $conn;
}

sub _db {
    my $conn_info = shift;
    return DBI->connect(
        "dbi:Pg:dbname=$conn_info->{dbname};host=$conn_info->{ip};port=$conn_info->{port};application_name=notify_pub;sslmode=require",
        'write',
        $conn_info->{password},
        {
            AutoCommit => 1,
            RaiseError => 1,
            PrintError => 0
        });
}

sub _redis {
    my $config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_TRANSACTION} // '/etc/rmg/redis-transaction.yml');
    # NOTICE
    # RedisDB has a weird behavior: Regardless the published string is encoded to utf8  or not, the listener always get the string that encoded to utf8.
    # Please revert to https://trello.com/c/SjSUWoQ1/7669-48-encoding-on-notifypub

    return RedisDB->new(
        host     => $config->{write}->{host},
        port     => $config->{write}->{port},
        password => $config->{write}->{password});
}

1;
