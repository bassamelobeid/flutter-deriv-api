#!/usr/bin/perl

use 5.010;
use strict;
use warnings;

use Date::Utility;
use BOM::Config::Chronicle;
use Quant::Framework::Asset;

# usage:
# perl ./bin/populate_new_dividends.pl 1HZ25V 1HZ50V 1HZ75V
for my $symbol (@ARGV) {
    my $otc_dividend = Quant::Framework::Asset->new(
        symbol           => $symbol,
        rates            => {365 => 0},
        recorded_date    => Date::Utility->new,
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
    );
    $otc_dividend->save;
}

1;
