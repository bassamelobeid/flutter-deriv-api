#!/usr/bin/perl
package main;
use strict;

use BOM::Platform::Plack qw( PrintContentType );
use f_brokerincludeall;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation("DAILY TURNOVER REPORT FOR " . request()->param('month'));
BOM::Platform::Auth0::can_access(['Accounts']);

my $args = request()->params;
$args->{broker}   ||= 'FOG';
$args->{month}    ||= Date::Utility->today->months_ahead(0);
$args->{whattodo} ||= 'TURNOVER';

Bar("DAILY TURNOVER REPORT for " . $args->{month});

my %template = DailyTurnOverReport($args);
BOM::Platform::Context::template->process(
    'backoffice/daily_turnover_report.html.tt',
    {
        dtr     => \%template,
        commas => \&commas,
    });

code_exit_BO();
