#!/usr/bin/perl

use strict;
use warnings;

=head1 NAME

migrate_from_myaffiliates.pl | It migrates affiliate user from MyAffiliates platform and saves them in bom-postgres-commissiondb

=head1 SYNOPSIS

# For QA testing, it fetches all account with test_type=ib_technical
./migrate_from_myaffiliates.pl --test=1

# To migrate all data from myaffiliates
./migrate_from_myaffiliates.pl --all=1

# For migrating account from a specific time. Leave out the dates if you want to do full migration.
./migrate_from_myaffiliates.pl --from_date=2021-06-01

=cut

use BOM::Platform::Email qw(send_email);
use BOM::Database::CommissionDB;
use BOM::User::Client;
use BOM::MyAffiliates;
use Parallel::ForkManager;
use Try::Tiny;
use Date::Utility;
use Getopt::Long;
use List::Util qw(min);
use Log::Any qw($log);
use Log::Any::Adapter qw(Stderr), log_level => $ENV{BOM_LOG_LEVEL} // 'warning';

# This is since the inception of JOIN_DATE on MyAffiliates.
my $inception_date = '2018-12-10';
# If this is not specified, it will be defaulted to current date.
my $now          = Date::Utility->new;
my $to_date      = $now->date;
my $from_date    = $now->minus_time_interval('1d')->date;
my $help         = 0;
my $test         = 0;
my $all          = 0;
my $ib_join_date = 0;

GetOptions(
    'f|from_date=s'    => \$from_date,
    't|to_date=s'      => \$to_date,
    'd|test=i'         => \$test,
    'x|all=i'          => \$all,
    'a|ib_join_date=i' => \$ib_join_date,
    'h|help=i'         => \$help,
);

pod2usage(1) if $help;

# Basic validation

# if we want to migrate all, override the dates
if ($all) {
    $to_date   = $now->date;
    $from_date = $inception_date;
}

try {
    $from_date = Date::Utility->new($from_date);
} catch {
    $log->warnf("Invalid --from_date [%s]", $from_date);
    pod2usage(1);
};

try {
    $to_date = Date::Utility->new($to_date);
} catch {
    $log->warnf("Invalid --to_date [%s]", $to_date);
    pod2usage(1);
};

if ($from_date->is_after($to_date)) {
    die 'from_date must be before to_date';
}

my $aff = BOM::MyAffiliates->new;
my $cms = BOM::Database::CommissionDB::rose_db();

# override $from_date if $test is true
$from_date = $to_date if $test;
my @dates = map { $from_date->plus_time_interval($_ . 'd')->date } (0 .. $to_date->days_between($from_date));
my (@parent_fail, @parent_success);

my $number_of_processes = min(4, scalar(@dates));
my $pm                  = Parallel::ForkManager->new($number_of_processes);

$pm->run_on_finish(
    sub {
        my ($pid, $exit_code, $ident, $exit_signal, $core_dump, $data_structure_reference) = @_;
        if ($data_structure_reference) {
            push @parent_fail,    $data_structure_reference->[0]->@*;
            push @parent_success, $data_structure_reference->[1]->@*;
        }
    });

foreach my $date (@dates) {
    $pm->start and next;

    my @fail    = ();
    my @success = ();

    $log->infof("Migration start for date=[%s]", $date);
    my %query_args =
        $test
        ? (
        VARIABLE_NAME  => 'test_type',
        VARIABLE_VALUE => 'ib_technical'
        )
        : $ib_join_date ? (
        VARIABLE_NAME  => 'ib_join_date',
        VARIABLE_VALUE => $date,
        )
        : (
        JOIN_DATE      => $date,
        VARIABLE_NAME  => 'affiliates_client_loginid',
        VARIABLE_VALUE => '%'
        );
    my $users = $aff->get_users(%query_args)->{USER};

    # no affiliate user for the $date
    unless ($users) {
        $log->infof("No user found for date=[%s]. Skipping...", $date);
        $pm->finish;
        next;
    }
    # if only a single user, ->get_users returns a HASH
    $users = [$users] if ref $users ne 'ARRAY';

    foreach my $user ($users->@*) {
        my $myaffiliate_id    = $user->{ID};
        my $myaffiliate_email = $user->{EMAIL};
        my $deriv_loginid     = _fetch_user_variable($user, 'affiliates_client_loginid');

        # can't proceed without $deriv_loginid defined
        if (not $deriv_loginid) {
            push @fail,
                {
                affiliate_id    => $myaffiliate_id,
                affiliate_email => $myaffiliate_email,
                reason          => 'Undefined affiliate_client_loginid'
                };
            $log->warnf("Failed to migrate affiliate id=[%s] with email=[%s] due to undefined affiliates_client_loginid",
                $myaffiliate_id, $myaffiliate_email);
            next;
        }

        my $deriv_client = BOM::User::Client->new({loginid => $deriv_loginid});

        # can't proceed without a valid $deriv_client
        if (not $deriv_client) {
            push @fail,
                {
                affiliate_id    => $myaffiliate_id,
                affiliate_email => $myaffiliate_email,
                reason          => sprintf("%s is not found in client database.", $deriv_loginid)};
            $log->warnf("Failed to migrate affiliate id=[%s] with email=[%s] due to invalid deriv login=[%s]",
                $myaffiliate_id, $myaffiliate_email, $deriv_loginid);
            next;
        }

        try {
            $cms->dbic->run(
                ping => sub {
                    $_->do(
                        'SELECT * FROM affiliate.add_new_affiliate(?,?,?,?,?)',
                        undef, $deriv_client->binary_user_id,
                        $myaffiliate_id, $deriv_loginid, $deriv_client->currency, 'myaffiliate'
                    );
                });
            push @success,
                {
                affiliate_id     => $myaffiliate_id,
                affiliate_email  => $myaffiliate_email,
                binary_user_id   => $deriv_client->binary_user_id,
                payment_loginid  => $deriv_loginid,
                payment_currency => $deriv_client->currency
                };
            $log->infof("Successful migration for affiliate id=[%s].", $myaffiliate_id);
        } catch {
            push @fail,
                {
                affiliate_id    => $myaffiliate_id,
                affiliate_email => $myaffiliate_email,
                reason          => $_
                };
            $log->warnf("Failed to migrate affiliate id=[%s] with email=[%s] due DB error", $myaffiliate_id, $myaffiliate_email);
        };
    }
    $pm->finish(0, [\@fail, \@success]);
}

$pm->wait_all_children;

_send_marketing_email(\@parent_fail, \@parent_success);
$log->infof("Migration complete. %s successful migration. %s failed.", scalar(@parent_success), scalar(@parent_fail));

## PRIVATE METHODS ##

sub _send_marketing_email {
    my ($fail, $success) = @_;

    my @failures = map {
        sprintf("Migration failed for affiliate id=[%s] with email=[%s]. Reason=[%s] %s", @{$_}{'affiliate_id', 'affiliate_email', 'reason'},
            '<br/>');
    } @$fail;

    my @successes = map {
        sprintf(
            "Migration successful for affiliate id=[%s] with email=[%s]. Details stored are binary_user_id=[%s], payment_loginid=[%s], payment_currency=[%s].<br/>",
            @{$_}{'affiliate_id', 'affiliate_email', 'binary_user_id', 'payment_loginid', 'payment_currency'})
    } @$success;

    my @message = ('<h2>Successful Migration </h2>', @successes, '<br/><h2>Failures:</h2>', @failures);

    send_email({
        from                  => 'no-reply@regentmarkets.com',
        to                    => 'x-marketing@regentmarkets.com',
        subject               => 'MyAffiliates Migration Report',
        message               => \@message,
        email_content_is_html => 1,
    });

    return;
}

sub _fetch_user_variable {
    my ($var_source, $var_name) = @_;

    foreach my $var ($var_source->{USER_VARIABLES}->{VARIABLE}->@*) {
        if ($var->{NAME} eq $var_name) {
            return $var->{VALUE};
        }
    }

    return undef;
}
