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
use BOM::Database::DataMapper::CollectorReporting;
PrintContentType();
#BrokerPresentation('MULTIBARRIER TRADING');
Bar("EXPOSURE REPORT for MULTIBARRIER TRADING");

my $args = request()->params;
$args->{broker} ||= 'FOG';

my $last_generated_time =
    BOM::Database::DataMapper::CollectorReporting->new({broker_code => 'CR'})->get_last_generated_historical_marked_to_market_time;

my $multibarrier_report = MultiBarrierReport($args);
BOM::Backoffice::Request::template->process(
    'backoffice/multibarrier.html.tt',
    {
        data            => $multibarrier_report,
        generated_time  => $last_generated_time,
    });

code_exit_BO();
