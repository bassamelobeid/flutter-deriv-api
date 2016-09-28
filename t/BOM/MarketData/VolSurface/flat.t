#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 1;
use Test::Exception;
use BOM::Market::Underlying;
use BOM::MarketData::VolSurface::Flat;
use BOM::System::Chronicle;

subtest 'everything' => sub {
    lives_ok {
        my $flat = BOM::MarketData::VolSurface::Flat->new(
            underlying => BOM::Market::Underlying->new('XYZ'),
            underlying_config => BOM::Market::Underlying->new('XYZ')->config,
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
        );
        ok !$flat->get_volatility, 'undef for unrecognized underlyings';
        $flat = BOM::MarketData::VolSurface::Flat->new(
            underlying => BOM::Market::Underlying->new('R_100'),
            underlying_config => BOM::Market::Underlying->new('R_100')->config,
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
        );
        is $flat->get_volatility, 1, '100% volatility for R_100';
        $flat = BOM::MarketData::VolSurface::Flat->new(
            underlying => BOM::Market::Underlying->new('R_25'),
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
            underlying_config => BOM::Market::Underlying->new('R_25')->config,
        );
        is $flat->get_volatility, 0.25, '25% volatility for R_25';
    }
    'nothing dies';
};
