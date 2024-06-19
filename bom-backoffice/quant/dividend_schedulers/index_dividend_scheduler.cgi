#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;
use JSON::MaybeUTF8          qw(:v1);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::DividendSchedulerTool;
use BOM::Backoffice::Request qw(request);

BOM::Backoffice::Sysinit::init();

PrintContentType();
my $r = request();

BrokerPresentation("Dividend Scheduler Tool");

my $disabled_write = not BOM::Backoffice::Auth::has_quants_write_access();
BOM::Backoffice::Request::template()->process(
    'backoffice/dividend_schedulers/index.html.tt',
    {
        sorted_datetime                   => $r->param('sorted_datetime'),
        index_dividend_scheduler          => BOM::Backoffice::DividendSchedulerTool::show_all($r->param('sorted_datetime')),
        edit_dividend_scheduler_url       => request()->url_for('backoffice/quant/dividend_schedulers/edit_dividend_scheduler.cgi'),
        dividend_scheduler_controller_url => request()->url_for('backoffice/quant/dividend_schedulers/dividend_scheduler_controller.cgi'),
        index_dividend_scheduler_url      => request()->url_for('backoffice/quant/dividend_schedulers/index_dividend_scheduler.cgi')}
) || die BOM::Backoffice::Request::template()->error;
