#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;
use JSON::MaybeUTF8          qw(:v1);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::DividendSchedulerTool;

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("Dividend Scheduler Tool");

my $disabled_write = not BOM::Backoffice::Auth::has_quants_write_access();
BOM::Backoffice::Request::template()->process(
    'backoffice/dividend_schedulers/main_page.html.tt',
    {
        new_dividend_scheduler_url   => request()->url_for('backoffice/quant/dividend_schedulers/new_dividend_scheduler.cgi'),
        index_dividend_scheduler_url => request()->url_for('backoffice/quant/dividend_schedulers/index_dividend_scheduler.cgi')}
) || die BOM::Backoffice::Request::template()->error;
