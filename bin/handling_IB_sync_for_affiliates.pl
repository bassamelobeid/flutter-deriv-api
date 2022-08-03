#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long;
use Pod::Usage;
use Date::Utility;
use BOM::MyAffiliates;
use BOM::Event::Actions::MyAffiliate;
use BOM::Platform::Event::Emitter;
use BOM::Platform::Email qw(send_email);
use Future::AsyncAwait;
use List::Util qw(uniq);
use Syntax::Keyword::Try;
use Log::Any qw($log);

use constant ONE_DAY => 24 * 60 * 60;

=head1 NAME

handling_IB_sync_for_affiliates.pl 

=head1 DESCRIPTION

We are gettinng timeout errors from MyAfffilieate API from affiliates that have over 40k clients.
This script handles IP sync for those affiliates by using limits on date ranges.

=head1 USAGE

=over 4

=item * affiliate_id is mandatory

=item * join_date is mandotory

=item * email is mandotory

=item * end_date is optional and defaults to current date

=item * m|month is optional and defaults to yearly

=item * l|log is optional and defaults to info

=item * help|h is optional

example: perl handling_IB_sync_for_affiliates.pl --affiliate_id=xxxxxx --join_date=2018-01-01 --email=test@test.com --end_date=2000-20-01 --m

=back

=cut

GetOptions(
    'affiliate_id=s' => \(my $affiliate_id = undef),
    'email=s'        => \(my $email        = undef),
    'join_date=s'    => \(my $join_date    = undef),
    'end_date=s'     => \(my $end_date     = undef),
    'm|month'        => \my $month_only,
    'l|log=s'        => \my $log_level,
    'help|h'         => \(my $printHelp = undef),
    )
    or die pod2usage(
    -verbose  => 0,
    -sections => ["NAME|DESCRIPTION|USAGE"]);

try {
    Log::Any::Adapter->import(qw(DERIV), log_level => $log_level // 'info');
} catch ($e) {
    die "ERROR: log not valid \n";
}

pod2usage(
    -exitval  => 1,
    -verbose  => 99,
    -sections => ["NAME|DESCRIPTION|USAGE"]) if ($printHelp);

pod2usage(
    -verbose => 0,
    -message => "\naffiliate_id is required \n"
) unless $affiliate_id;

pod2usage(
    -verbose => 0,
    -message => "\njoin_date is required \n"
) unless $join_date;

pod2usage(
    -verbose => 0,
    -message => "\nemail is required \n"
) unless $email;

$log->infof("affiliate_id = %s", $affiliate_id);

# verify date format
my $date;
$log->infof("join_date = %s", $join_date);

try {
    $date = Date::Utility->new($join_date);
} catch ($e) {
    die "ERROR: join date not valid \n";
}

my $final_date;
if ($end_date) {
    $log->infof("join_date = %s", $end_date);
    try {
        $final_date = Date::Utility->new($end_date);
    } catch ($e) {
        die "ERROR: end date not valid \n";
    }
} else {
    $final_date = Date::Utility->today();
}
my $current_date = Date::Utility->today();
if ($date->is_after($current_date)) {
    die "ERROR: join date is after current date! \n";
}

=head1 METHODS

=head2 get_pairs
Subroutine to retrieve all the join_date\end_date pairs with 1 year appart or 1 month apart

=over 4

=item * C<$p> The start date of the operation.

=item * C<$pairs> Array of date pairs

=back

example for year :
2020-10-01 to 2021-12-02 will produce  => (2020-10-01, 2021-10-01), (2021-10-01, 2021-12-02)

=cut

sub get_pairs {
    my $p         = shift;
    my @pairs     = ();
    my $plus_type = $month_only ? "_plus_months" : "_plus_years";

    while (!$p->$plus_type(1)->is_after($final_date)) {
        my %pair = (
            AFFILIATE_ID => $affiliate_id,
            FROM_DATE    => $p->date_yyyymmdd,
            TO_DATE      => $p->$plus_type(1)->date_yyyymmdd
        );
        push(@pairs, \%pair);
        $p = $p->$plus_type(1)->plus_time_interval(ONE_DAY);
    }

    if ($p->$plus_type(1)->is_after($final_date) && $final_date->is_after($p)) {
        my %pair = (
            AFFILIATE_ID => $affiliate_id,
            FROM_DATE    => $p->date_yyyymmdd,
            TO_DATE      => $final_date->date_yyyymmdd
        );
        push(@pairs, \%pair);
    }

    return @pairs;
}

sub affiliate_sync_initiated {
    $log->infof("processing...");
    my @login_ids = _get_clean_loginids()->@*;

    while (my @chunk = splice(@login_ids, 0, BOM::Event::Actions::MyAffiliate::AFFILIATE_CHUNK_SIZE)) {
        my $args = {
            loginids     => [@chunk],
            affiliate_id => $affiliate_id,
            email        => $email,
            action       => 'sync'
        };
        BOM::Platform::Event::Emitter::emit('affiliate_loginids_sync', $args);
    }
    return 0;
}

sub _get_clean_loginids {
    my @date_pairs    = get_pairs($date);
    my $my_affiliate  = BOM::MyAffiliates->new(timeout => 300);
    my @all_customers = ();
    for my $pairs (@date_pairs) {
        my $customers = $my_affiliate->get_customers($pairs);
        if (scalar @$customers == 0 && WebService::MyAffiliates::errstr) {
            foreach (WebService::MyAffiliates::errstr) {
                $log->error($_);
            }
        }
        my @ids = uniq
            grep { !/${BOM::User->MT5_REGEX}/ }
            map  { s/^deriv_//r }
            map  { $_->{CLIENT_ID} || () } @$customers;
        $log->infof(sprintf("Retreiving customers between %s to %s : %d", $pairs->{FROM_DATE}, $pairs->{TO_DATE}, scalar @ids));
        push(@all_customers, @ids);
    }
    $log->infof(sprintf("Total number of customers: %d", scalar @all_customers));

    return [@all_customers];
}

#start here
affiliate_sync_initiated();

