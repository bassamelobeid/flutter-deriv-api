package BOM::Platform::Script::NotifyPub;

use strict;
use warnings;

=head1 NAME

BOM::Platform::Script::NotifyPub - monitor database transactions and pass notifications through Redis

=head1 DESCRIPTION

This script is a critical part of the system for notifying clients and other parts of the code
when there's a new transaction.

Since it's handling PostgreSQL C<NOTIFY> events, delays here can cause major performance issues
in other database queries, so it's essential to B<avoid adding any further code> to this file
without going through careful design and review.

=cut

use 5.010;
use YAML::XS;
use DBI;
use DBD::Pg;
use IO::Select;
use Syntax::Keyword::Try;
use RedisDB;
use JSON::MaybeUTF8 qw(:v1);

my @conn;

sub run {
    @conn = _master_db_connections();
    my $forks = 0;
    my @cpid;
    foreach my $addr (@conn) {
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
                    my $dbh   = _db($addr);

                    $dbh->do("LISTEN transaction_watchers_json");
                    my $sel = IO::Select->new;
                    $sel->add($dbh->{pg_socket});
                    while ($sel->can_read) {
                        while (my $notify = $dbh->pg_notifies) {
                            my ($name, $pid, $payload) = @$notify;
                            _publish($redis, _msg($payload));
                        }
                    }
                } catch ($e) {
                    warn "$0 ($$): saw exception: $e";
                    sleep 1;
                }
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
            payment_id amount balance_after transaction_time short_code currency_code purchase_time purchase_price sell_time payment_remark client_loginid binary_user_id/
    } = decode_json_utf8($payload)->@*;

    return \%msg;
}

sub _master_db_connections {
    my @conn = ('vr01', 'cr01', 'mx01', 'mf01', 'mlt01', 'crw01', 'vrw01', 'mfw01');
    if ($ENV{BOM_TEST_ON_QA}) {
        # Unit test env, specific only to QA:
        @conn = ('cr01_test');
    }
    return @conn;
}

sub _db {
    my $conn_info = shift;
    return DBI->connect(
        "dbi:Pg:service=$conn_info;application_name=notify_pub",
        undef, undef,
        {
            AutoCommit => 1,
            RaiseError => 1,
            PrintError => 0
        });
}

sub _redis {
    my $config = YAML::XS::LoadFile('/etc/rmg/redis-transaction.yml');
    # NOTICE
    # RedisDB has a weird behavior: Regardless the published string is encoded to utf8  or not, the listener always get the string that encoded to utf8.
    # Please revert to https://trello.com/c/SjSUWoQ1/7669-48-encoding-on-notifypub

    return RedisDB->new(
        host     => $config->{write}->{host},
        port     => $config->{write}->{port},
        password => $config->{write}->{password});
}

1;
