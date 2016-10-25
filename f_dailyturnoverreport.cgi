#!/etc/rmg/bin/perl
package main;
use strict;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use f_brokerincludeall;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("DAILY TURNOVER REPORT FOR " . request()->param('month'));
BOM::Backoffice::Auth0::can_access(['Accounts', 'Quants', 'IT']);

my $args = request()->params;
$args->{broker}   ||= 'FOG';
$args->{month}    ||= Date::Utility->today->months_ahead(0);
$args->{whattodo} ||= 'TURNOVER';

Bar("DAILY TURNOVER REPORT for " . $args->{month});

my %template = DailyTurnOverReport($args);
BOM::Backoffice::Request::template->process(
    'backoffice/daily_turnover_report.html.tt',
    {
        dtr        => \%template,
        commas     => \&commas,
        this_month => $args->{month},
    });

code_exit_BO();
