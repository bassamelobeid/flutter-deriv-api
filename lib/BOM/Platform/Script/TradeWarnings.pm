package BOM::Platform::Script::TradeWarnings;

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
use BOM::Platform::Email qw(send_email);

my $json = JSON::MaybeXS->new;
my %notification_cache;
my $cache_epoch = Date::Utility->today->epoch;

sub _publish {
    my $redis = shift;
    my $msg   = shift;

    my ($subject, $email_list, $status);
    # trading is suspended. So sound the alarm!
    if ($msg->{current_amount} >= $msg->{limit_amount}) {
        $status     = 'disabled';
        $subject    = "TRADING SUSPENDED! $msg->{type} LIMIT is crossed for landing company $msg->{landing_company}.";
        $email_list = 'x-quants@binary.com,x-marketing@binary.com,compliance@binary.com,x-cs@binary.com';
    } else {
        $status     = 'threshold_crossed';
        $subject    = "$msg->{type} THRESHOLD is crossed for landing company $msg->{landing_company}.";
        $email_list = 'x-quants@binary.com';
    }

    # cache for a day
    _refresh_notification_cache() if (time - $cache_epoch > 86400);

    my $warning_key = join '_', ($status, $msg->{type}, $msg->{landing_company}, $msg->{limit_amount});
    unless ($notification_cache{$warning_key}) {
        # it is JSON::PP::Boolean, so converting it to 1 or 0 for json->encode to work properly
        $msg->{rank}->{is_market_default} = $msg->{rank}->{is_market_default} ? 1 : 0;
        send_email({
            from    => 'system@binary.com',
            to      => $email_list,
            subject => $subject . " Limit set: $msg->{limit_amount}. Current amount: $msg->{current_amount}",
            message => [$json->encode($msg->{rank})],
        });
        $notification_cache{$warning_key} = 1;
    }

    return;
}

sub _refresh_notification_cache {
    %notification_cache = ();
    $cache_epoch        = Date::Utility->today->epoch;
    return;
}

sub _master_db_connections {
    my $config = YAML::XS::LoadFile('/etc/rmg/clientdb.yml');
    return map { ref $config->{$_} ? [$_, $config->{$_}->{write}->{ip}, $config->{password}] : () } keys %$config;
}

sub _db {
    my ($ip, $pw) = @_;
    my $db_postfix = $ENV{DB_POSTFIX} // '';
    return DBI->connect(
        "dbi:Pg:dbname=regentmarkets$db_postfix;host=$ip;port=5432;application_name=trade_warnings;sslmode=require",
        write => $pw,
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

sub run {
    my %kids;

    local $SIG{INT} = sub {
        say "$$: Got signal: @_";
        foreach my $p (values %kids) {
            next unless @$p > 3;
            say "$$: Killing $p->[3] (lc: $p->[0])";
            kill TERM => $p->[3];
        }
    };
    local $SIG{TERM} = $SIG{INT};

    foreach my $cf (_master_db_connections()) {
        say "$$: setting up config $cf->[0]";
        my $pid;
        # yes, this `select` emulates `sleep`. But the built-in `sleep` can only
        # sleep for entire seconds. There is no point in loading an external module
        # only to sleep for half a second. So, shut up! This is perfectly valid Perl.
        # Further, the explanation in the PBP book page 168 justifies this
        # requirement only because it's "ugly". However, even the official Perl
        # documentation (`perldoc -f select`) mentions this usage of `select`.
        # So, please, Damian Conway, shut up and learn Perl properly before
        # publishing such "best practices".
        select undef, undef, undef, 0.3 until defined($pid = fork);    ## no critic
        if ($pid) {                                                    # parent
            $cf->[3] = $pid;
            $kids{$pid} = $cf;
            next;
        }

        # although both @SIG{qw/TERM INT/} have been localized above
        # perlcritic is still complaining. Hence, no critic.
        $SIG{TERM} = $SIG{INT} = 'DEFAULT';    ## no critic
        %kids = ();

        # child
        my ($lc, $ip, $pw) = @$cf;
        say "$$: starting to listen on $ip ($lc)";

        while (1) {
            try {
                my $redis = _redis();
                my $dbh = _db($ip, $pw);

                $dbh->do("LISTEN trade_warning");

                my $sel = IO::Select->new;
                $sel->add($dbh->{pg_socket});
                while ($sel->can_read) {
                    while (my $notify = $dbh->pg_notifies) {
                        my ($name, $pid, $payload) = @$notify;
                        my $msg = $json->decode($payload);
                        $msg->{landing_company} = $lc;
                        _publish($redis, $msg);
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

    while (keys %kids) {
        my $pid = wait();
        my $cf  = delete $kids{$pid};
        say "$$: Parent saw $pid ($cf->[0]) exiting" if $cf;
    }
    return 0;
}

1;
