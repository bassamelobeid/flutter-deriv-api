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
BrokerPresentation('MULTIBARRIER TRADING');
Bar("EXPOSURE REPORT for MULTIBARRIER TRADING");

my $args = request()->params;
$args->{broker}   ||= 'FOG';

my $multibarrier_report = MultiBarrierReport($args);
BOM::Backoffice::Request::template->process(
    'backoffice/multibarrier.html.tt',
    {
        data       => $multibarrier_report,
        risk_report_url =>  request()->url_for('backoffice/f_dailyturnoverreport.cgi'), 
    });

code_exit_BO();
