package BOM::Platform::Script::TradeWarnings;

use strict;
use warnings;
use 5.010;
use YAML::XS;
use DBI;
use DBD::Pg;
use IO::Select;
use Syntax::Keyword::Try;
use JSON::MaybeXS;
use Log::Any qw($log);
use BOM::Platform::Email qw(send_email);

my $json = JSON::MaybeXS->new;
my %notification_cache;
my $cache_epoch = Date::Utility->today->epoch;

sub _publish {
    my ($msg, $new_clients_limit) = @_;
    $log->debugf('Client with binary user id %s crossed a limit of %s', $msg->{binary_user_id}, $msg->{limit_amount});
    # Only send email warnings when limit is crossed from what we've specified for new clients
    # trello.com/c/S4BGlHHv/1754-remove-user-limit-email-notification
    if ($msg->{type} =~ /^user/ && defined $new_clients_limit && $msg->{current_amount} < $new_clients_limit) {
        $log->debugf(
            'Skip sending notification email for %s on user %s: %s < %s',
            $msg->{type},
            $msg->{binary_user_id},
            $msg->{current_amount},
            $new_clients_limit
        );
        return;
    }

    my ($subject, $email_list, $status);
    # trading is suspended. So sound the alarm!
    if ($msg->{current_amount} >= $msg->{limit_amount}) {
        $status = 'disabled';
        $subject =
            $msg->{type} =~ /^global/
            ? "TRADING SUSPENDED! $msg->{type} LIMIT is crossed for landing company $msg->{landing_company}."
            : "TRADING SUSPENDED! $msg->{type} LIMIT is crossed for user $msg->{binary_user_id} loginid $msg->{client_loginid}.";
        $email_list = 'x-quants@binary.com,x-marketing@binary.com,compliance@binary.com,x-cs@binary.com';
    } else {
        $status = 'threshold_crossed';
        $subject =
            $msg->{type} =~ /^global/
            ? "$msg->{type} THRESHOLD is crossed for landing company $msg->{landing_company}."
            : "$msg->{type} THRESHOLD is crossed for user $msg->{binary_user_id}. loginid $msg->{client_loginid}";
        $email_list = 'x-quants@binary.com';
    }

    # cache for a day
    _refresh_notification_cache() if (time - $cache_epoch > 86400);

    my $warning_key = join '_', ($status, $msg->{type}, $msg->{landing_company}, $msg->{limit_amount});
    unless ($notification_cache{$warning_key}) {
        # it is JSON::PP::Boolean, so converting it to 1 or 0 for json->encode to work properly
        $msg->{rank}->{is_market_default} =
            $msg->{rank}->{is_market_default}
            ? 1
            : 0;
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
    my $conn;
    foreach my $lc (keys %{$config}) {
        if (ref $config->{$lc}) {
            my $data = $config->{$lc}->{write};
            my $port;

            if ($ENV{DB_TEST_PORT}) {
                # Unit test env, specific only to QA:
                $port = $ENV{DB_TEST_PORT};
                $data->{dbname} = 'cr_test';
            }

            $data->{dbname}   //= 'regentmarkets';
            $data->{password} //= $config->{password};
            # conn contains a hash ref which contains conection details needed per database
            $conn->{$lc} = {
                ip       => $data->{ip},
                dbname   => $data->{dbname},
                password => $data->{password},
                port     => $port // 5432,
                lc       => $lc,
            };
        }
    }
    return $conn;
}

sub _db {
    my $conn_info = shift;
    return DBI->connect(
        "dbi:Pg:dbname=$conn_info->{dbname};host=$conn_info->{ip};port=$conn_info->{port};application_name=trade_warnings;sslmode=require",
        write => $conn_info->{password},
        {
            AutoCommit => 1,
            RaiseError => 1,
            PrintError => 0
        });
}

sub _get_new_clients_limit {
    my $dbh = shift;
    my $lc_loss_limit =
        $dbh->selectcol_arrayref(q/SELECT potential_loss FROM betonmarkets.user_specific_limits WHERE binary_user_id IS NULL AND client_type='new'/);
    return $lc_loss_limit->[0] // undef;
}

sub run {

    my %kids;

    local $SIG{INT} = sub {
        my $signame = shift;
        $log->infof('%d: Got signal: %s', $$, $signame);
        foreach my $p (values %kids) {
            next unless exists $p->{pid};
            $log->debugf('%d: Killing %d (lc: %s)', $$, $p->{pid}, $p->{lc});
            kill TERM => $p->{pid};
        }
    };
    local $SIG{TERM} = $SIG{INT};

    my $conn = _master_db_connections();
    my @lcs  = keys %{$conn};
    $log->infof('%d: setting up configs for %s', $$, \@lcs);
    foreach my $lc (@lcs) {
        $log->debugf('%d: setting up config %s', $$, $lc);

        my $connection_details = $conn->{$lc};
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
            $connection_details->{pid} = $pid;
            $kids{$pid} = $connection_details;
            next;
        }
        # although both @SIG{qw/TERM INT/} have been localized above
        # perlcritic is still complaining. Hence, no critic.
        $SIG{TERM} = $SIG{INT} = 'DEFAULT';    ## no critic
        %kids = ();

        # child
        $log->debugf('%d: starting to listen on %s/%s (%s)', $$, $connection_details->{ip}, $connection_details->{dbname}, $lc);

        while (1) {
            try {
                my $dbh = _db($connection_details);
                $dbh->do("LISTEN trade_warning");
                my $limit = _get_new_clients_limit($dbh);
                my $sel   = IO::Select->new;
                $sel->add($dbh->{pg_socket});
                while ($sel->can_read) {
                    while (my $notify = $dbh->pg_notifies) {
                        my ($name, $pid, $payload) = @$notify;
                        my $msg = $json->decode($payload);
                        $msg->{landing_company} = $connection_details->{lc};
                        _publish($msg, $limit);
                    }
                }
            } catch ($e) {
                $log->warnf('%s (%d): saw exception: %s', $0, $$, $e);
                sleep 1;
            }
        }
        exit;
    }

    while (keys %kids) {
        my $pid = wait();
        my $cf  = delete $kids{$pid};
        $log->debugf('%d: Parent saw %d (%s) exiting', $$, $pid, $cf->{lc}) if $cf;
    }
    $log->info('Stopping binary_limits-notification serivce - TradeWarning process terminated');
    return 0;
}

1;
