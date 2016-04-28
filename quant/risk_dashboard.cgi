#!/usr/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use Format::Util::Numbers qw( to_monetary_number_format );
use BOM::RiskReporting::Dashboard;
use BOM::Platform::Runtime;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('Risk Dashboard.');

Bar('Risk Dashboard');

my $report = BOM::RiskReporting::Dashboard->new->fetch;

my $today = Date::Utility->today;

$report->{dtr_link} = request()->url_for('backoffice/f_dailyturnoverreport.cgi');

$report->{link_to_pnl} = sub {
    my $loginid = shift;
    my ($broker) = ($loginid =~ /^([A-Z]+)\d+$/);
    return request()->url_for(
        "backoffice/f_profit_table.cgi",
        {
            loginID   => $loginid,
            broker    => $broker,
            startdate => Date::Utility->new->minus_time_interval('180d')->datetime,
            enddate   => Date::Utility->new->plus_time_interval('1d')->datetime,
        });
};
$report->{monify}  = \&to_monetary_number_format;
$report->{commas} = \&commas;
$report->{titlfy}  = sub {
    my $href  = shift;
    my $title = $href->{name};

    if ($href->{being_watched_for}) {
        $title .= "\n" . '[' . $href->{being_watched_for} . ']';
    }
    return $title;
};
$report->{aff_titlfy} = sub {
    my $href = shift;

    return $href->{username} . ' (' . $href->{email} . ')';
};
BOM::Platform::Context::template->process('backoffice/risk_dashboard.html.tt', $report);

code_exit_BO();
