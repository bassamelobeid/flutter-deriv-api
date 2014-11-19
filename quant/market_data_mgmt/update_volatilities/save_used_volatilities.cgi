#!/usr/bin/perl
package main;

use strict 'vars';

use lib qw(/home/git/regentmarkets/bom-backoffice);
use f_brokerincludeall;
use BOM::Platform::Runtime;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Market::PricingInputs::VolSurface::Delta;
use BOM::Market::PricingInputs::Volatility::Display;

system_initialize();
$\ = "\n";
PrintContentType();

my $markets        = request()->param('markets');
my $warndifference = request()->param('warndifference');

my @markets = split /\s+/, $markets;

my $dm = BOM::Market::PricingInputs::Couch::VolSurface->new;

BrokerPresentation("", "");

foreach my $market (@markets) {
    my $underlying = BOM::Market::Underlying->new($market);

    local $/ = "\n";

    #------------------------Get the old/in-use/existing volatility ---------------------------------
    my $existing_vol_surface = $dm->fetch_surface({underlying => $underlying});
    my $display = BOM::Market::PricingInputs::Volatility::Display->new(surface => $existing_vol_surface);

    local $/ = "";

    print "<TABLE BORDER = 2 bgcolor = #00AAAAA width=99% >";
    print "<TR>";
    print "<TD>";
    print "<iframe frameborder=0 width=100% height=340 scrolling=yes ";
    print "src='" . request()->url_for('backoffice/quant/edit_vol.cgi', {symbol => $market}) . "' ";
    print "border=0 marginheight=0 marginwidth=0 vspace=0>";
    print "</iframe>";
    print "</TD>";

    print "</TABLE>";

}

print "<form method=post action='" . request()->url_for('backoffice/quant/market_data_mgmt/update_volatilities/update_used_volatilities.cgi') . "'>";
print qq~<input type=hidden size=10 name=markets value="$markets">~;
print "<TABLE BORDER = 2 bgcolor = #00AAAAA width=99% ><TR><TD align = center>";
print "<input type=submit value='BACK'>";
print "</TD></TR></TABLE>";
print "</form><br><hr><br>";

code_exit_BO();

