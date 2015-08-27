#!/usr/bin/perl

BEGIN {
    push @INC, "/home/git/regentmarkets/bom/cgi", "/home/git/regentmarkets/bom-backoffice/lib";
}

use strict;
use warnings;
use Getopt::Long;

use Date::Utility;
use BOM::Utility::Log4perl qw( get_logger );
use BOM::Platform::Sysinit ();
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Runtime;
use BOM::DailySummaryReport;

BOM::Utility::Log4perl::init_log4perl_console;
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

my $logger = get_logger;

# By default we run all brokers and currencies for today.
$for_date ||= Date::Utility->new->date_yyyymmdd;

my @brokercodes = ($brokercodes) ? split(/,/, $brokercodes) : BOM::Platform::Runtime->instance->broker_codes->all_codes;
my @currencies  = ($currencies)  ? split(/,/, $currencies)  : BOM::Platform::Runtime->instance->landing_companies->all_currencies;

# This report will now only be run on the MLS.
if (not BOM::Platform::Runtime->instance->hosts->localhost->has_role('master_live_server')) {
    exit 0;
}

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

$logger->debug('Finished.');

1;
