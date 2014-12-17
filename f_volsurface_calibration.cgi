#!/usr/bin/perl
package main;

use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use BOM::Market::UnderlyingDB;
use BOM::Platform::Runtime;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::MarketData::Display::VolatilitySurface;
use CGI;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('CALIBRATION MODEL COMPARISON');

BOM::Platform::Auth0::can_access(['Quants']);

my $cgi = CGI->new();
my @underlyings =
    ($cgi->param('underlyings'))
    ? split ',',
    $cgi->param('underlyings')
    : BOM::Market::UnderlyingDB->instance->get_symbols_for(
    market       => 'indices',
    broker       => 'VRT',
    bet_category => 'risefall',
    );

my $calibrate = $cgi->param('calibrate');
my (%calibration_results, $template_name);
my $display = BOM::MarketData::Display::VolatilitySurface->new();
foreach my $underlying_symbol (@underlyings) {
    if ($calibrate) {
        $calibration_results{$underlying_symbol} = $display->volsurface_calibration_result($underlying_symbol);
        $template_name = 'backoffice/calibrator_param.html.tt';
    } else {
        $calibration_results{$underlying_symbol} = $display->fetch_calibration_param($underlying_symbol);
        $template_name = 'backoffice/manual_update_calibration_param.html.tt';
    }
}

Bar('Update VolSurface Parameterization');
print process_param(\%calibration_results, $template_name);

sub process_param {
    my ($calibration_results, $template_name) = @_;

    my $html;
    BOM::Platform::Context::template->process(
        $template_name,
        {
            params          => $calibration_results,
            save_action_url => request()->url_for('backoffice/f_update_calibration.cgi'),
        },
        \$html
    ) || die BOM::Platform::Context::template->error;

    return $html;
}
