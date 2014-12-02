#!/usr/bin/perl
package main;

use strict;
use warnings;

use lib qw(/home/git/regentmarkets/bom-backoffice);
use f_brokerincludeall;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::MarketData::Fetcher::VolSurface;
use BOM::MarketData::Display::VolatilitySurface;

system_initialize();

$\ = "";
PrintContentType();

my $underlying_symbol = request()->param('underlying') || 'frxEURUSD';
my $underlying = BOM::Market::Underlying->new($underlying_symbol);

my @days_to_expiry = (1,  7,  30);
my @moneyness      = (25, 50, 75);
my @errors;

# This doesn't seem to make sense any more.
my $dm = BOM::MarketData::Fetcher::VolSurface->new;
my $vol_surface = $dm->fetch_surface({underlying => $underlying});

BrokerPresentation();

Bar("Input parameters");
print "<form method=post action='" . request()->url_for("backoffice/quant/market_data_mgmt/update_volatilities/plot_volsurface.cgi") . "'>";
print "Underlying: <input type=text name=underlying_symbol value='$underlying_symbol'> <br />";
print "<input type=submit value='Go'>";
print "</form>";

Bar("Smile Flags for $underlying_symbol");
print '<h3>Volatility Surface in use:</h3>';
print $vol_surface->get_smile_flags;

Bar('Volatility Smiles for ' . $underlying->symbol);
my $display = BOM::MarketData::Display::VolatilitySurface->new(surface => $vol_surface);
foreach my $day_to_expiry (@days_to_expiry) {
    print $display->plot_smile_or_termstructure({
            days_to_expiry => $day_to_expiry,
            title          => "$day_to_expiry day smile for $underlying_symbol",
    });
}

Bar("Volatility Termstructures for $underlying_symbol");
foreach my $moneyness (@moneyness) {
    print $display->plot_smile_or_termstructure({
            moneyness => $moneyness,
            title     => "$moneyness delta termstructure for $underlying_symbol",
    });
}

code_exit_BO();
