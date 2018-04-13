#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use BOM::Backoffice::PlackHelpers qw/PrintContentType_excel PrintContentType/;
use BOM::Backoffice::Request qw(request localize);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Config;

BOM::Backoffice::Sysinit::init();

PrintContentType();

unless ((grep { $_ eq 'binary_role_master_server' } @{BOM::Platform::Config::node()->{node}->{roles}})) {
    code_exit_BO("WARNING! You are not on the Master Live Server. Suggest you use these tools on the Master Live Server instead.");
}

BrokerPresentation('Aggregate Balance Per Currency');

my $report_mapper = BOM::Database::DataMapper::CollectorReporting->new({
    broker_code => 'FOG',
    operation   => 'collector'
});
my $results = $report_mapper->get_aggregate_balance_per_currency();

my $records;
foreach my $entry (@$results) {
    $records->{$entry->{currency_code}}->{$entry->{broker_code}} += $entry->{balance};
}

BOM::Backoffice::Request::template->process(
    'backoffice/aggregate_balance.html.tt',
    {
        records => $records,
    }) || die BOM::Backoffice::Request::template->error(), "\n";

code_exit_BO();
