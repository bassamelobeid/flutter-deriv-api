#!/usr/bin/perl

use 5.010;
use strict;
use warnings;

use Date::Utility;
use BOM::Market::Underlying;
use BOM::MarketData::VolSurface::Moneyness;
use BOM::MarketData::Dividend;
use BOM::Market::UnderlyingDB;

my $date = Date::Utility->new;
my @symbols_to_update= BOM::Market::UnderlyingDB->instance->get_symbols_for(market => 'stocks', submarket => ['france','belgium','amsterdam']);

for my $symbol (@symbols_to_update) {
    my $u      = BOM::Market::Underlying->new($symbol);
    my $v      = BOM::MarketData::VolSurface::Moneyness->new({
            underlying          => $u,
            surface             => {'ON' => {smile => {100 => 0.2, 98 => 0.2, 102 => 0.2, 80 => 0.3, 120 =>0.23}},
                                    '1W' => {smile => {100 => 0.2, 98 =>0.2, 102 => 0.2, 80 => 0.33, 120 =>0.23}},
                                    '1M' => {smile => {100 => 0.2, 98 =>0.2, 102 => 0.2, 80 =>0.335, 120 => 0.23}},
                                    '2M' => {smile => {100 => 0.2, 98 =>0.2, 102 => 0.2, 80 =>0.335, 120 => 0.23}}},
            recorded_date       => $date,
            master_cutoff       => 'UTC 16:30',
            spot_reference      => 100,

    });
    say $symbol. ' ' . $v->save;
    my $d = BOM::MarketData::Dividend->new(
        rates  => {365 => 0},
        symbol => $u->system_symbol,
        recorded_date   => $date,
    );
    say $symbol. ' ' . $d->save;
}

1;
