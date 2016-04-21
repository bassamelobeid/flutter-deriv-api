#!/usr/bin/perl

use strict;
use warnings;

# Path to find Global.pm in the t/ directory
use FindBin;
use lib "$FindBin::Bin/../..";    #cgi
use Test::More qw(no_plan);

package t::feeds::markets;
use BOM::Market::Underlying;

my @symbols = ('frxUSDJPY', 'FRXEURUSD', 'frXAUDJPY');
foreach my $symbol (@symbols) {
    my $underlying = BOM::Market::Underlying->new($symbol);
    my $market     = $underlying->market->name;
    Test::More::is($market, 'forex', "$symbol belongs to $market market");
}

@symbols = ('UKBARC', 'UKBP');
foreach my $symbol (@symbols) {
    my $underlying = BOM::Market::Underlying->new($symbol);
    my $market     = $underlying->market->name;
    Test::More::is($market, 'stocks', "$symbol belongs to $market market");
}

@symbols = ('USINTC', 'USAAPL');
foreach my $symbol (@symbols) {
    my $underlying = BOM::Market::Underlying->new($symbol);
    my $market     = $underlying->market->name;
    Test::More::is($market, 'stocks', "$symbol belongs to $market market");
}

@symbols = ('FCHI', 'FTSE');
foreach my $symbol (@symbols) {
    my $underlying = BOM::Market::Underlying->new($symbol);
    my $market     = $underlying->market->name;
    Test::More::is($market, 'indices', "$symbol belongs to $market market");
}

@symbols = ('R_50', 'R_100');
foreach my $symbol (@symbols) {
    my $underlying = BOM::Market::Underlying->new($symbol);
    my $market     = $underlying->market->name;
    Test::More::is($market, 'volidx', "$symbol belongs to $market market");
}

