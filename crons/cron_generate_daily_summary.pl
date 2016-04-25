#!/usr/bin/perl

BEGIN {
    push @INC, "/home/git/regentmarkets/bom/cgi", "/home/git/regentmarkets/bom-backoffice/lib";
}

use strict;
use warnings;
use Getopt::Long;

use Date::Utility;
use BOM::System::Localhost;
use BOM::Platform::Sysinit ();
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Runtime;
use BOM::DailySummaryReport;

BOM::Platform::Sysinit::init();

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

my @brokercodes = ($brokercodes) ? split(/,/, $brokercodes) : BOM::Platform::Runtime->instance->broker_codes->all_codes;
my @currencies  = ($currencies)  ? split(/,/, $currencies)  : BOM::Platform::Runtime->instance->landing_companies->all_currencies;

# This report will now only be run on the master server
exit 0 unless (BOM::System::Localhost::is_master_server());

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
send_email({
    'from'    => 'system@binary.com',
    'to'      => BOM::Platform::Runtime->instance->app_config->accounting->email,
    'subject' => 'Daily Outstanding Bets Profit / Lost [' . $run_for->date . ']',
    'message' => \@mail_msg,
});

1;
