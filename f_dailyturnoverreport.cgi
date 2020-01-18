#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use HTML::Entities;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use f_brokerincludeall;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use Format::Util::Numbers qw(commas);
BOM::Backoffice::Sysinit::init();

PrintContentType();

my $args = request()->params;
$args->{broker} ||= 'FOG';
my $today = Date::Utility->today;
$args->{month} ||= $today->year . '-' . sprintf("%02d", $today->month);
$args->{whattodo} ||= 'TURNOVER';

$args->{month} = encode_entities($args->{month});
Bar("DAILY TURNOVER REPORT for " . $args->{month});
BrokerPresentation("DAILY TURNOVER REPORT FOR " . $args->{month});

my %template = DailyTurnOverReport($args);
BOM::Backoffice::Request::template()->process(
    'backoffice/daily_turnover_report.html.tt',
    {
        dtr        => \%template,
        commas     => \&commas,
        this_month => $args->{month},
    });

code_exit_BO();
