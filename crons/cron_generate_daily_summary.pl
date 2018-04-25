#!/etc/rmg/bin/perl
use strict;
use warnings;

BEGIN {
    push @INC, "/home/git/regentmarkets/bom/cgi", "/home/git/regentmarkets/bom-backoffice/lib";
}

use Getopt::Long;

use Brands;
use Date::Utility;
use BOM::Platform::Config;
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Utility qw(master_live_server_error);
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Runtime;
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

# By default we run all brokers and currencies for today.
$for_date ||= Date::Utility->new->date_yyyymmdd;

my @brokercodes = ($brokercodes) ? split(/,/, $brokercodes) : LandingCompany::Registry::all_broker_codes;
my @currencies  = ($currencies)  ? split(/,/, $currencies)  : LandingCompany::Registry->new()->all_currencies;

# This report will now only be run on the master server
master_live_server_error() unless ((grep { $_ eq 'binary_role_master_server' } @{BOM::Platform::Config::node()->{node}->{roles}}));

my $run_for = Date::Utility->new($for_date);

my $total_pl = BOM::DailySummaryReport->new(
    for_date    => $for_date,
    currencies  => \@currencies,
    brokercodes => \@brokercodes,
    broker_path => BOM::Platform::Runtime->instance->app_config->system->directory->db . '/f_broker/',
)->generate_report;

my @mail_msg;
foreach my $broker (keys %{$total_pl}) {
    foreach my $currency (keys %{$total_pl->{$broker}}) {
        push @mail_msg, "$broker, $currency, $total_pl->{$broker}->{$currency}";
    }
}
my $brand = Brands->new(name => request()->brand);
send_email({
    'from'    => $brand->emails('system'),
    'to'      => 'i-payments@binary.com',
    'subject' => 'Daily Outstanding Bets Profit / Lost [' . $run_for->date . ']',
    'message' => \@mail_msg,
});

1;
