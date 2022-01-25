#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;
use JSON::MaybeUTF8 qw(:v1);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::DividendSchedulerTool;
use BOM::Config;
use LandingCompany::Registry;
use BOM::Config::QuantsConfig;

BOM::Backoffice::Sysinit::init();
my $r = request();

PrintContentType();
BrokerPresentation("Edit Dividend Scheduler");

BOM::Backoffice::Request::template()->process(
    'backoffice/dividend_schedulers/edit.html.tt',
    {
        dividend_scheduler                => BOM::Backoffice::DividendSchedulerTool::show($r->param('id')),
        dividend_scheduler_controller_url => request()->url_for('backoffice/quant/dividend_schedulers/dividend_scheduler_controller.cgi'),
        mt5_webapi_configs                => BOM::Config->mt5_webapi_config->{real},
        mt5_symbols                       => BOM::Config::QuantsConfig->get_dividend_scheduler_yml->{symbols}->{mt5_underlyings},
        payout_currencies                 => _get_payout_currencies(),
        new_dividend_scheduler_url        => request()->url_for('backoffice/quant/dividend_schedulers/new_dividend_scheduler.cgi'),
        index_dividend_scheduler_url      => request()->url_for('backoffice/quant/dividend_schedulers/index_dividend_scheduler.cgi'),
    }) || die BOM::Backoffice::Request::template()->error;

sub _get_payout_currencies {
    my $legal_allowed_currencies = LandingCompany::Registry::get('svg')->legal_allowed_currencies;
    my @payout_currencies;

    foreach my $currency (keys %{$legal_allowed_currencies}) {
        push @payout_currencies, $currency;
    }

    # @additional_currencies is for adding additional currencies that is not available in LandingCompany::Registry::get('svg')->legal_allowed_currencies
    my @additional_currencies = qw(JPY CHF);
    push @payout_currencies, @additional_currencies;

    return \@payout_currencies;
}
