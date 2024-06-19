#!/etc/rmg/bin/perl

use strict;
use warnings;

use Getopt::Long;
use Pod::Find qw(pod_where);
use Pod::Usage;

use BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve;
use BOM::Config::CurrencyConfig;
use DataDog::DogStatsd::Helper qw/stats_inc/;
use Log::Any::Adapter;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

=head1 NAME

autoapprove.pl

=head1 SYNOPSIS

perl autoapprove.pl [options]

Options
  -h, -?, --help: print brief help
  -l, --log: verbosity level to configure the logger. Defaults to 'info'
  --approve: boolean flag to enable actual approval of payouts, if false, no changes will be performed
  -p, --acceptable_percentage: percentage limit for payouts to be considered too risky to auto-approve
  -t, --threshold_amount: the upper limit in USD for the each withdrawal. Payouts exceeding this amount won't be auto-approved
  -a, --allowed_above_threshold: boolean flag to remove upper limit for the total amount that has been withdrawn in the configured time span
  -b, --broker_code: broker code of clients to be processed
  --threshold_amount_per_day: the upper limit in USD for the total amount that has been withdrawn in current day inclusive of currently LOCKED withdrawals, payouts after this amount won't be auto-approved 
  -e, --excluded_currencies : comma separated currency_code(s) to exclude specific currencies from auto-approval.
=head1 DESCRIPTION

Entry point for C<BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve>, see module's documentation for details about how it works, argument valid options and approval rules.

=cut

sub print_help {
    pod2usage({
            -verbose  => 99,
            -sections => "NAME|SYNOPSIS|DESCRIPTION|OPTIONS",
            -input    => pod_where({-inc => 1}, 'BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve')});
}

GetOptions(
    'h|?|help'                    => \my $help,
    'l|log=s'                     => \my $log_level,
    'p|acceptable_percentage=i'   => \my $acceptable_percentage,
    't|threshold_amount=i'        => \my $threshold_amount,
    'threshold_amount_per_day=i'  => \my $threshold_amount_per_day,
    'a|allowed_above_threshold=i' => \my $allowed_above_threshold,
    'b|broker_code=s'             => \my $broker_code,
    'e|excluded_currencies=s'     => \my $excluded_currencies,
) or print_help;
print_help if $help;

Log::Any::Adapter->import(
    qw(DERIV),
    stdout    => 'json',
    log_level => $log_level // 'info'
);

stats_inc('crypto.payments.autoapprove.heartbeat');

my $is_approval_enabled_globally = BOM::Config::CurrencyConfig::get_crypto_payout_auto_update_global_status('approve')         // 0;
my $is_dry_run                   = BOM::Config::CurrencyConfig::get_crypto_payout_auto_update_global_status('approve_dry_run') // 0;

if ($is_approval_enabled_globally) {

    my $auto_approve = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve->new(
        broker_code              => $broker_code // 'CR',
        acceptable_percentage    => $acceptable_percentage,
        threshold_amount         => $threshold_amount,
        threshold_amount_per_day => $threshold_amount_per_day,
        allowed_above_threshold  => $allowed_above_threshold,
    );

    $auto_approve->run(
        is_dry_run          => $is_dry_run,
        excluded_currencies => $excluded_currencies // ''
    );
}
