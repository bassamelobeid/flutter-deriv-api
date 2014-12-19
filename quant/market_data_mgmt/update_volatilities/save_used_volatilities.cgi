#!/usr/bin/perl
package main;

use strict 'vars';

use lib qw(/home/git/regentmarkets/bom-backoffice);
use f_brokerincludeall;
use BOM::Platform::Runtime;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::MarketData::VolSurface::Delta;
use BOM::MarketData::Display::VolatilitySurface;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();

my $markets = request()->param('markets');
my @markets = split /\s+/, $markets;
my $dm      = BOM::MarketData::Fetcher::VolSurface->new;
BrokerPresentation("", "");

foreach my $symbol (@markets) {
    local $/ = "\n";
    my $underlying           = BOM::Market::Underlying->new($symbol);
    my $existing_vol_surface = $dm->fetch_surface({underlying => $underlying});
    my $display              = BOM::MarketData::Display::VolatilitySurface->new(surface => $existing_vol_surface);
    local $/ = "";

    print "<TABLE BORDER = 2 bgcolor = #00AAAAA width=99% >";
    print "<TR>";
    print "<TD>";
    print '<form action="' . request()->url_for('backoffice/f_save.cgi') . '" method="post" name="editform">';
    print '<input type="hidden" name="filen" value="editvol">';
    print '<input type="hidden" name="symbol" value="' . $symbol . '">';
    print '<input type="hidden" name="l" value="EN">';
    print "<textarea name='text' rows=15 cols=75>";
    print join "\n", $display->rmg_text_format;
    print "</textarea>";

    if ($existing_vol_surface->type eq 'moneyness') {
        print 'Spot reference: <input type="text" name="spot_reference" value="' . $existing_vol_surface->spot_reference . '">';
    }
    print '<input type="submit" value="Save">';
    print "</TD>";

    print "</TABLE>";

}

code_exit_BO();

