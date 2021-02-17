#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings

use lib qw(/home/git/regentmarkets/bom-backoffice);
use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();

#-----------------------------------INPUT from other programm-------------------------
my $currencies = request()->param('currencies');

my @currencies = split /\s+/, $currencies;

BrokerPresentation("Update Interest Rates");

foreach my $currency (@currencies) {
    Bar("$currency rates");
    print "<TABLE class='border full-width'>";

    print "<TD>";
    print "<iframe frameborder=0 width=100% height=300 scrolling=yes ";
    print "src='" . request()->url_for("backoffice/quant/edit_interest_rate.cgi", {symbol => $currency}) . "' ";
    print "border=0 marginheight=0 marginwidth=0 vspace=0>";
    print "</iframe>";
    print "</TD>";

    print "</TABLE><br>";

}

code_exit_BO();

