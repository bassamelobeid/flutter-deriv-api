#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use HTML::Entities;

use lib qw(/home/git/regentmarkets/bom-backoffice);
use f_brokerincludeall;
use BOM::Config::Runtime;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Display::VolatilitySurface;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();

my $markets = request()->param('markets');
my @markets = split /\s+/, $markets;
my $dm      = BOM::MarketData::Fetcher::VolSurface->new;
BrokerPresentation("", "");

foreach my $symbol (@markets) {
    local $/ = "\n";
    my $underlying = create_underlying($symbol);
    # when we are updating surface, fetch New York 10 for FX
    my $args = {
        underlying => $underlying,
    };
    my $existing_vol_surface = $dm->fetch_surface($args);
    my $display = BOM::MarketData::Display::VolatilitySurface->new(surface => $existing_vol_surface);
    local $/ = "";

    print "<TABLE BORDER = 2 bgcolor = #00AAAAA width=99% >";
    print "<TR>";
    print "<TD>";
    print '<form action="' . request()->url_for('backoffice/f_save.cgi') . '" method="post" onsubmit="return setSymbolValue(this);" name="editform">';
    print '<input type="hidden" name="underlying" value="' . encode_entities($symbol) . '">';
    print "<textarea name='info_text' rows=15 cols=75>";
    print join "\n", $display->rmg_text_format;
    print "</textarea>";

    if ($existing_vol_surface->type eq 'moneyness') {
        print 'Spot reference: <input type="text" name="spot_reference" value="'
            . encode_entities($existing_vol_surface->spot_reference)
            . '" data-lpignore="true" />';
    }
    print '<input type="submit" value="Save">';

    print '<input type="hidden" name="filen" value="editvol"/>';
    print '<input type="hidden" name="symbol"/>';
    print "<textarea name='text' rows=15 cols=75 style='display:none;'></textarea>";
    print '<input type="hidden" name="l" value="EN">';

    print '</form>';
    print "</TD>";

    print "</TABLE>";

}
code_exit_BO();

