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
use Log::Any                   qw($log);
use BOM::Platform::Email       qw(send_email);
use DataDog::DogStatsd::Helper qw(stats_event);
use Brands;
use BOM::Config::Redis;
use DateTime;

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

    if ($msg->{type} =~ /^accumulator/) {
        _publish_accumulator_aggregate_stake_error($msg);
        return;
    }

    my ($subject, $email_list, $status);
    my $brand         = Brands->new(name => 'deriv');
    my $message_title = $msg->{type};

    # replacing the underscore with whitespace.
    $message_title =~ s/_/ /g;

    # trading is suspended. So sound the alarm!
    if ($msg->{current_amount} >= $msg->{limit_amount}) {
        # storing global limits into redis-hash
        _store_global_limits($msg);
        $status = 'disabled';
        $subject =
            $msg->{type} =~ /^global/
            ? "Trading suspended! $message_title LIMIT is hit."
            : "Trading suspended! $message_title LIMIT is crossed for user $msg->{binary_user_id} loginid $msg->{client_loginid}.";
        $email_list = join ", ", map { $brand->emails($_) } qw(quants compliance cs marketing_x);
    } else {
        $status = 'threshold_crossed';
        $subject =
            $msg->{type} =~ /^global/
            ? "$message_title THRESHOLD is crossed for landing company $msg->{landing_company}."
            : "$message_title THRESHOLD is crossed for user $msg->{binary_user_id}. loginid $msg->{client_loginid}";
        $email_list = $brand->emails('quants');
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
        my $message_body = $json->encode(_parse_email_parameters($msg));
        send_email({
            from    => 'system@binary.com',
            to      => $email_list,
            subject => $subject . " Limit set: $msg->{limit_amount}. Current amount: $msg->{current_amount}",
            message => [$message_body],
        });

        stats_event(
            $subject,
            $message_body,
            {
                alert_type => 'warning',
                tags       => ['trade_warning:hit_limit']});

        $notification_cache{$warning_key} = 1;
    }

    return;
}

=head2 _publish_accumulator_aggregate_stake_error

send alert to DD if the message is related to accumulator aggregate stake limit

=cut

sub _publish_accumulator_aggregate_stake_error {
    my $msg = shift;

    my $message_body = $json->encode($msg);
    my $key;
    my $subject;

    if ($msg->{type} =~ /^accumulator_half/) {
        $subject = "Accumulator max_aggregate_open_stake is crossing half of the threshold";
        $key     = join '_', ('Accumulator', $msg->{symbol}, $msg->{growth_rate}, 'max_aggregate_stake', 'halfway');
    } else {
        $subject = "Accumulator max_aggregate_open_stake is crossing the threshold";
        $key     = join '_', ('Accumulator', $msg->{symbol}, $msg->{growth_rate}, 'max_aggregate_stake', 'crossed');
    }

    unless (BOM::Config::Redis::redis_replicated_read()->exists($key)) {
        my $brand      = Brands->new(name => 'deriv');
        my $email_list = join ", ", map { $brand->emails($_) } qw(quants);

        send_email({
            from    => 'system@binary.com',
            to      => $email_list,
            subject => $subject,
            message => [$message_body],
        });

        BOM::Config::Redis::redis_replicated_write()->set($key, 1, 'EX', 3600);
    }

    stats_event(
        $subject,
        $message_body,
        {
            alert_type => 'warning',
            tags       => ['trade_warning:hit_limit']});
}

sub _refresh_notification_cache {
    %notification_cache = ();
    $cache_epoch        = Date::Utility->today->epoch;
    return;
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
        "dbi:Pg:service=$conn_info;application_name=trade_warnings",
        undef, undef,
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

=head2 _parse_email_parameters

parsing email parameters

=cut

sub _parse_email_parameters {
    my $message = shift;
    my %parsed_message;

    my @root_keys = qw(comment start_time end_time limit_amount current_amount landing_company);
    map { $parsed_message{$_} = $message->{$_} } @root_keys;

    my @rank_keys = qw(is_atm expiry_type contract_group market symbol is_market_default);
    map { $parsed_message{$_} = $message->{rank}->{$_} } @rank_keys;

    return \%parsed_message;
}

=head2 _is_defined

Checking if the given value is defined and if it is not defined, it return 'default'

=cut

sub _is_defined {
    my $check = shift;
    return $check ? $check : "default";
}

=head2 _store_global_limits

When Global Realized loss limit crossed, it stores in a redis hash with an expiry of next date. 

=cut

sub _store_global_limits {
    my $msg = shift;
    my $key = "global::limits";
    if ($msg->{landing_company} =~ /cr/) {
        $msg->{landing_company_short} = "svg";
    } elsif ($msg->{landing_company} =~ /mx/) {
        $msg->{landing_company_short} = "iom";
    } elsif ($msg->{landing_company} =~ /mlt/) {
        $msg->{landing_company_short} = "malta";
    } elsif ($msg->{landing_company} =~ /mf/) {
        $msg->{landing_company_short} = "maltainvest";
    } else {
        $msg->{landing_company_short} = undef;
    }

    my $hash_key =
          _is_defined($msg->{rank}{market}) . "::"
        . _is_defined($msg->{rank}{expiry_type}) . "::"
        . _is_defined($msg->{rank}{is_atm}) . "::"
        . _is_defined($msg->{rank}{contract_group}) . "::"
        . _is_defined($msg->{landing_company}) . "::"
        . _is_defined($msg->{type}) . "::"
        . _is_defined($msg->{limit_amount});

    my $encoded_msg = $json->encode($msg);
    my $ttl         = DateTime->today(time_zone => 'local')->add(days => 1)->epoch - time;
    my $redis       = BOM::Config::Redis::redis_replicated_write();
    $redis->hset($key, $hash_key, $encoded_msg);
    $redis->expire($key, $ttl);
    return;
}

sub run {

    my %connection_details;

    local $SIG{INT} = sub {
        my $signame = shift;
        $log->infof('%d: Got signal: %s', $$, $signame);
        foreach my $lc (keys %connection_details) {
            next unless exists $connection_details{$lc};
            my $pid = $connection_details{$lc};
            $log->debugf('%d: Killing %d (lc: %s)', $$, $pid, $lc);
            kill TERM => $pid;
        }
    };
    local $SIG{TERM} = $SIG{INT};

    my @conn = _master_db_connections();
    my @lcs  = @conn;
    $log->infof('%d: setting up configs for %s', $$, \@lcs);
    foreach my $lc (@lcs) {
        $log->debugf('%d: setting up config for %s', $$, $lc);

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
            $connection_details{$lc} = $pid;
            next;
        }
        # although both @SIG{qw/TERM INT/} have been localized above
        # perlcritic is still complaining. Hence, no critic.
        $SIG{TERM} = $SIG{INT} = 'DEFAULT';             ## no critic
        %connection_details = ();

        # child
        $log->debugf('%d: starting to listen on %s ', $$, $lc);

        while (1) {
            try {
                my $dbh = _db($lc);
                $dbh->do("LISTEN trade_warning");
                my $limit = _get_new_clients_limit($dbh);
                my $sel   = IO::Select->new;
                $sel->add($dbh->{pg_socket});
                while ($sel->can_read) {
                    while (my $notify = $dbh->pg_notifies) {
                        my ($name, $pid, $payload) = @$notify;
                        my $msg = $json->decode($payload);
                        $msg->{landing_company} = $lc;
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

    foreach my $lc (keys %connection_details) {
        my $pid = wait();
        $pid = delete $connection_details{$lc};
        $log->debugf('%d: Parent saw %d (%s) exiting', $$, $pid, $lc) if $pid;
    }
    $log->info('Stopping binary_limits-notification serivce - TradeWarning process terminated');
    return 0;
}

1;
