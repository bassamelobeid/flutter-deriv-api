#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Warnings;
use Test::Exception;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::VolSurface::Flat;
use BOM::Config::Chronicle;
use LandingCompany::Registry;

subtest 'everything' => sub {
    lives_ok {
        my $flat = BOM::MarketData::VolSurface::Flat->new(
            underlying       => create_underlying('XYZ'),
            underlying       => create_underlying('XYZ'),
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        );
        throws_ok { $flat->get_volatility } qr/volatility not defined/, 'throws an error when volatility is undefined for symbol';

        my $offerings = LandingCompany::Registry->by_name('virtual')->basic_offerings({
            loaded_revision => 1,
            action          => 'buy'
        });
        my @symbols      = grep { $_ ne 'stpRNG' } $offerings->query({market => 'synthetic_index'}, ['underlying_symbol']);
        my %expected_vol = (
            'RDBEAR'    => 1.55,
            'RDBULL'    => 1.75,
            'R_100'     => 1,
            'R_10'      => 0.1,
            'R_25'      => 0.25,
            'R_50'      => 0.5,
            'R_75'      => 0.75,
            'RDYANG'    => 1.75,
            'RDYIN'     => 1.55,
            '1HZ100V'   => 1,
            '1HZ150V'   => 1.5,
            '1HZ200V'   => 2,
            '1HZ250V'   => 2.5,
            '1HZ300V'   => 3,
            '1HZ10V'    => 0.1,
            '1HZ25V'    => 0.25,
            '1HZ50V'    => 0.5,
            '1HZ75V'    => 0.75,
            'CRASH300N' => 1,
            'BOOM300N'  => 1,
            CRASH1000   => 0.21,
            BOOM1000    => 0.21,
            CRASH500    => 0.31,
            BOOM500     => 0.31,
            JD10        => 0.1323,
            JD25        => 0.3307,
            JD50        => 0.6614,
            JD75        => 0.9922,
            JD100       => 1.3229,
            WLDUSD      => 0.1,
            WLDGBP      => 0.1,
            WLDAUD      => 0.1,
            WLDEUR      => 0.1,
            WLDXAU      => 0.25,
        );
        foreach my $symbol (@symbols) {
            my $flat = BOM::MarketData::VolSurface::Flat->new(
                underlying       => create_underlying($symbol),
                chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
            );
            is $flat->get_volatility, $expected_vol{$symbol}, 'correct volatility for ' . $symbol;
        }
    }
    'nothing dies';
};
