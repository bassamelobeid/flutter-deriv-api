#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Exception;
use Test::NoWarnings;
use BOM::Market::Underlying;
use BOM::MarketData::VolSurface::Flat;

subtest 'everything' => sub {
    lives_ok {
        my $flat = BOM::MarketData::VolSurface::Flat->new(
            underlying => BOM::Market::Underlying->new('XYZ'),
        );
        ok !$flat->get_volatility, 'undef for unrecognized underlyings';
        $flat = BOM::MarketData::VolSurface::Flat->new(
            underlying => BOM::Market::Underlying->new('R_100'),
        );
        is $flat->get_volatility, 1, '100% volatility for R_100';
        $flat = BOM::MarketData::VolSurface::Flat->new(
            underlying => BOM::Market::Underlying->new('R_25'),
        );
        is $flat->get_volatility, 0.25, '25% volatility for R_25';
        is $flat->cutoff->code, 'UTC 23:59', 'has cutoff at close';
    }
    'nothing dies';
};
