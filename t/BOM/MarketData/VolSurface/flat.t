#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Warnings;
use Test::Exception;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::VolSurface::Flat;
use BOM::Config::Chronicle;

subtest 'everything' => sub {
    lives_ok {
        my $flat = BOM::MarketData::VolSurface::Flat->new(
            underlying       => create_underlying('XYZ'),
            underlying       => create_underlying('XYZ'),
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        );
        is $flat->get_volatility, 0.1, '0.1 for unrecognized underlyings';
        $flat = BOM::MarketData::VolSurface::Flat->new(
            underlying       => create_underlying('R_100'),
            underlying       => create_underlying('R_100'),
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        );
        is $flat->get_volatility, 1, '100% volatility for R_100';
        $flat = BOM::MarketData::VolSurface::Flat->new(
            underlying       => create_underlying('R_25'),
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
            underlying       => create_underlying('R_25'),
        );
        is $flat->get_volatility, 0.25, '25% volatility for R_25';
    }
    'nothing dies';
};
