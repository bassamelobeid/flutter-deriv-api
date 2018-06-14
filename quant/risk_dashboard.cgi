#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use BOM::RiskReporting::Dashboard;
use BOM::Config::Runtime;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();
PrintContentType();
BrokerPresentation('Risk Dashboard.');

Bar('Risk Dashboard');

my $report = BOM::RiskReporting::Dashboard->new->fetch;

my $today = Date::Utility->today;

$report->{dtr_link}         = request()->url_for('backoffice/f_dailyturnoverreport.cgi');
$report->{multibarrier}     = BOM::RiskReporting::Dashboard->new->multibarrierreport();
$report->{exposures_report} = BOM::RiskReporting::Dashboard->new->exposures_report();

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
$report->{titlfy} = sub {
    my $href  = shift;
    my $title = $href->{name};

    if ($href->{being_watched_for}) {
        $title .= "\n" . '[' . $href->{being_watched_for} . ']';
    }
    return $title;
};
$report->{aff_titlfy} = sub {
    my $href     = shift;
    my $username = $href->{username};
    my $email    = $href->{email};

    return ($email and $username) ? $username . ' (' . $email . ')' : ($username // $email);
};

BOM::Backoffice::Request::template()->process('backoffice/risk_dashboard.html.tt', $report);

code_exit_BO();
