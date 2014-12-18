#!/usr/bin/perl
package main;

use strict 'vars';

use lib qw(/home/git/regentmarkets/bom-backoffice);
use f_brokerincludeall;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();

#-----------------------------------INPUT from other programm-------------------------
my $currencies = request()->param('currencies');

my @currencies = split /\s+/, $currencies;

BrokerPresentation("", "");

foreach my $currency (@currencies) {

    print "<TABLE BORDER = 2 bgcolor = #00AAAAA width=99% >";

    print "<TD>";
    print "<iframe frameborder=0 width=100% height=300 scrolling=yes ";
    print "src='" . request()->url_for("backoffice/quant/edit_interest_rate.cgi", {symbol => $currency}) . "' ";
    print "border=0 marginheight=0 marginwidth=0 vspace=0>";
    print "</iframe>";
    print "</TD>";

    print "</TABLE>";

}

code_exit_BO();

