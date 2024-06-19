#!/etc/rmg/bin/perl

use strict;
use warnings;

# Path to find Global.pm in the t/ directory
use FindBin;
use lib "$FindBin::Bin/../..";    #cgi
use Test::More qw(no_plan);

package t::feeds::markets;
use BOM::MarketData qw(create_underlying);

my @symbols = ('frxUSDJPY', 'FRXEURUSD', 'frXAUDJPY');
foreach my $symbol (@symbols) {
    my $underlying = create_underlying($symbol);
    my $market     = $underlying->market->name;
    Test::More::is($market, 'forex', "$symbol belongs to $market market");
}

@symbols = ('FCHI', 'FTSE');
foreach my $symbol (@symbols) {
    my $underlying = create_underlying($symbol);
    my $market     = $underlying->market->name;
    Test::More::is($market, 'indices', "$symbol belongs to $market market");
}

@symbols = ('R_50', 'R_100');
foreach my $symbol (@symbols) {
    my $underlying = create_underlying($symbol);
    my $market     = $underlying->market->name;
    Test::More::is($market, 'synthetic_index', "$symbol belongs to $market market");
}

