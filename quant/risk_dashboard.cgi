#!/usr/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use BOM::Utility::Format::Numbers qw( to_monetary_number_format );
use BOM::Product::RiskReporting::Dashboard;
use BOM::Platform::Runtime;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('Risk Dashboard.');

Bar('Risk Dashboard');

my $report = BOM::Product::RiskReporting::Dashboard->new->fetch;

my $today = BOM::Utility::Date->today;

$report->{dtr_link} = request()->url_for('backoffice/f_dailyturnoverreport.cgi');

$report->{link_to_pnl} = sub {
    my $loginid = shift;
    my ($broker) = ($loginid =~ /^([A-Z]+)\d+$/);
    return request()->url_for(
        "backoffice/f_profit_table.cgi",
        {
            loginID   => $loginid,
            broker    => $broker,
            startdate => BOM::Utility::Date->new->minus_time_interval('180d')->datetime,
            enddate   => BOM::Utility::Date->new->plus_time_interval('1d')->datetime,
        });
};
$report->{monify}  = \&to_monetary_number_format;
$report->{virgule} = \&virgule;
$report->{titlfy}  = sub {
    my $href  = shift;
    my $title = $href->{name};

    if ($href->{custom_limits}) {
        foreach my $limit (@{$href->{custom_limits}}) {
            my $payout_amount = $limit->{payout_limit} // 'no limit';
            $title .=
                  "\n" . '['
                . $limit->{market} . '-'
                . $limit->{contract_kind} . ': '
                . $payout_amount . '] '
                . $limit->{comment} . ' ('
                . $limit->{staff} . ','
                . $limit->{modified} . ')';
        }
    }
    return $title;
};
$report->{aff_titlfy} = sub {
    my $href = shift;

    return $href->{username} . ' (' . $href->{email} . ')';
};
BOM::Platform::Context::template->process('backoffice/risk_dashboard.html.tt', $report);

code_exit_BO();
