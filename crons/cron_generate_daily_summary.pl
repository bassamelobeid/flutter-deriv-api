#!/etc/rmg/bin/perl
use strict;
use warnings;

BEGIN {
    push @INC, "/home/git/regentmarkets/bom/cgi", "/home/git/regentmarkets/bom-backoffice/lib";
}

use Getopt::Long;
use Path::Tiny qw(path);
use Text::CSV;

use Date::Utility;

use BOM::Config;
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Utility qw(master_live_server_error);
use BOM::Platform::Email qw(send_email);
use BOM::Config::Runtime;
use BOM::DailySummaryReport;

use LandingCompany;
use LandingCompany::Registry;

BOM::Backoffice::Sysinit::init();

my ($jobs, $currencies, $brokercodes, $for_date);
my $optres = GetOptions(
    'broker-codes=s' => \$brokercodes,
    'currencies=s'   => \$currencies,
    'date=s'         => \$for_date,
);

if (!$optres) {
    print STDERR join(' ', 'Usage:', $0, '[--broker-codes=CR[,MLT[,...]]]', '[--currencies=USD[,GBP[,...]]]', '[--date=2009-12-25]',);
    exit;
}

my $csv = Text::CSV->new({
    eol        => "\n",
    quote_char => undef
});

# By default we run all brokers and currencies for today.
$for_date ||= Date::Utility->new->date_yyyymmdd;

my @brokercodes = ($brokercodes) ? split(/,/, $brokercodes) : LandingCompany::Registry::all_broker_codes;
my @currencies  = ($currencies)  ? split(/,/, $currencies)  : LandingCompany::Registry->new()->all_currencies;

# This report will now only be run on the master server
master_live_server_error() unless ((grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}}));

my $total_pl = BOM::DailySummaryReport->new(
    for_date    => $for_date,
    currencies  => \@currencies,
    brokercodes => \@brokercodes,
    broker_path => BOM::Config::Runtime->instance->app_config->system->directory->db . '/f_broker/',
)->generate_report;

my @csv_rows;

foreach my $broker (keys %{$total_pl}) {
    foreach my $currency (keys %{$total_pl->{$broker}}) {
        my $csv_row = [$broker, $currency, $for_date, $total_pl->{$broker}->{$currency}];
        push @csv_rows, $csv_row;
    }
}

# CSV creation starts here
my $filename = 'daily_open_trades_' . $for_date . '.csv';

{
    use autodie qw(close);

    my $file = path($filename)->openw_utf8;

    my @headers = ('Broker', 'Currency', 'Date', 'Open_trades_PL');
    $csv->print($file, \@headers);
    $csv->print($file, $_) for @csv_rows;

    close $file;
}

# CSV creation ends here

my $brand = request()->brand;
send_email({
    'from'       => $brand->emails('system'),
    'to'         => 'i-payments@binary.com',
    'subject'    => 'Daily Outstanding Bets Profit / Lost [' . $for_date . ']',
    'attachment' => $filename,
});

path($filename)->remove;

1;
