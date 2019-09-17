#!/usr/bin/perl

use 5.010;
use strict;
use warnings;

use Date::Utility;
use BOM::Config::Chronicle;

for my $symbol (qw(1HZ100V 1HZ10V)) {
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
