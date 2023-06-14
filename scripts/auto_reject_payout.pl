#!/etc/rmg/bin/perl

use strict;
use warnings;

use Getopt::Long;
use Pod::Find qw(pod_where);
use Pod::Usage;

use BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject;
use BOM::Config::CurrencyConfig;
use DataDog::DogStatsd::Helper qw/stats_inc/;
use Log::Any::Adapter;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

=head1 NAME

auto_reject_payout.pl

=head1 SYNOPSIS

perl auto_reject_payout.pl [options]

Options
  -h, -?, --help: print brief help
  -l, --log: verbosity level to configure the logger. Defaults to 'info'
  --reject: boolean flag to enable actual reject of payouts, if false, no changes will be performed
  -b, --broker_code: broker code of clients to be processed
  -e, --excluded_currencies : comma separated currency_code(s) to exclude specific currencies from auto-reject
=head1 DESCRIPTION

Entry point for C<BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject>, see module's documentation for details about how it works, argument valid options and reject rules.

=cut

sub print_help {
    pod2usage({
            -verbose  => 99,
            -sections => "NAME|SYNOPSIS|DESCRIPTION|OPTIONS",
            -input    => pod_where({-inc => 1}, 'BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject')});
}

GetOptions(
    'h|?|help'                => \my $help,
    'l|log=s'                 => \my $log_level,
    'b|broker_code=s'         => \my $broker_code,
    'e|excluded_currencies=s' => \my $excluded_currencies,
) or print_help;
print_help if $help;

Log::Any::Adapter->import(
    qw(DERIV),
    stdout    => 'json',
    log_level => $log_level // 'info'
);

stats_inc('crypto.payments.autoreject.heartbeat');

my $is_reject_enabled_globally = BOM::Config::CurrencyConfig::get_crypto_payout_auto_update_global_status('reject')         // 0;
my $is_dry_run                 = BOM::Config::CurrencyConfig::get_crypto_payout_auto_update_global_status('reject_dry_run') // 0;

if ($is_reject_enabled_globally) {
    my $auto_reject = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject->new(broker_code => $broker_code // 'CR');
    $auto_reject->run(
        is_dry_run          => $is_dry_run,
        excluded_currencies => $excluded_currencies
    );
}
