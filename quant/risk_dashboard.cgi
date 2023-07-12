#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use BOM::RiskReporting::Dashboard;
use BOM::RiskReporting::VanillaRiskReporting;
use BOM::Config::Runtime;
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit      ();
use Syntax::Keyword::Try;
use Data::Dump qw(pp);
use CGI;
BOM::Backoffice::Sysinit::init();
PrintContentType();
BrokerPresentation('Risk Dashboard.');

Bar('Risk Dashboard');

my $report = BOM::RiskReporting::Dashboard->new->fetch;

my $today = Date::Utility->today;

my $cgi = CGI->new;
$report->{dtr_link}                    = request()->url_for('backoffice/f_dailyturnoverreport.cgi');
$report->{exposures_report}            = BOM::RiskReporting::Dashboard->new->exposures_report();
$report->{multiplier_open_pnl}         = BOM::RiskReporting::Dashboard->new->multiplier_open_pnl_report();
$report->{vanilla_risk_report}         = BOM::RiskReporting::VanillaRiskReporting->new->vanilla_risk_report();
$report->{vanilla_risk_report_at_date} = Date::Utility->new->datetime;

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

if ($cgi->request_method() eq 'POST') {
    my $at_date = $cgi->param('at_date');

    try {
        $at_date                               = Date::Utility->new($at_date);
        $report->{vanilla_risk_report}         = BOM::RiskReporting::VanillaRiskReporting->new->vanilla_risk_report($at_date);
        $report->{vanilla_risk_report_at_date} = $at_date->datetime;

        $report->{vanilla_error_message} = "No record found." unless $report->{vanilla_risk_report};
    } catch ($e) {
        $report->{vanilla_error_message} = "Error occured (Are you using the right date format?) : " . pp($e);
    };

}

BOM::Backoffice::Request::template()->process('backoffice/risk_dashboard.html.tt', $report);

code_exit_BO();
