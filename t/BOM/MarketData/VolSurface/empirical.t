#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::Exception;
use Test::FailWarnings;
use Format::Util::Numbers qw/roundnear/;

use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
initialize_realtime_ticks_db();

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::MarketData::VolSurface::Empirical;
use BOM::Market::Underlying;
use BOM::Market::UnderlyingDB;
use BOM::Market::AggTicks;
use Time::Duration::Concise::Localize;
use Date::Utility;

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('exchange', {symbol => 'FOREX'});
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency', {symbol => 'USD'});
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency', {symbol => 'JPY'});
my $now = Date::Utility->new('2015-05-17 10:00');
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });

my $duration = Time::Duration::Concise->new(interval => '15m');
my $underlying = BOM::Market::Underlying->new('frxUSDJPY');
for (my $i = $duration->seconds; $i > 0; $i--) {
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - $i,
        underlying => $underlying->symbol,
        quote      => 100 + int(rand(100)) / 100
    });
}
my $at = BOM::Market::AggTicks->new;
$at->fill_from_historical_feed({
    underlying   => $underlying,
    ending_epoch => $now->epoch,
    interval     => $duration,
});

subtest 'seasonalized naked volatility' => sub {
    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => $underlying,
        date_start   => $now,
        date_pricing => $now,
        duration     => $duration->normalized_code,
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 10
    });
    is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'correct pricing engine';
    my $emp = BOM::MarketData::VolSurface::Empirical->new(underlying => $underlying);
    cmp_ok(
        roundnear(
            1e-4,
            $emp->get_seasonalized_volatility({
                    current_epoch         => $c->date_pricing->epoch,
                    seconds_to_expiration => $c->timeindays->amount * 86400,
                }
            )->{volatility}
        ),
        '==', 0.1955,
        'seasonalized volatility matches'
    );
};

subtest 'seasonalized naked volatility with news' => sub {
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'economic_events',
        {
            recorded_date => $now,
            release_date  => Date::Utility->new($now->epoch + 10),
            date          => Date::Utility->new(),
            impact        => 5,
        },
    );
    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => $underlying,
        date_start   => $now,
        date_pricing => $now,
        duration     => $duration->normalized_code,
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 10
    });
    is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'correct pricing engine';
    my $emp = BOM::MarketData::VolSurface::Empirical->new(underlying => $underlying);
    cmp_ok(
        roundnear(
            1e-3,
            $emp->get_seasonalized_volatility_with_news({
                    current_epoch         => $c->date_pricing->epoch,
                    seconds_to_expiration => $c->timeindays->amount * 86400,
                }
            )->{volatility}
        ),
        '==', 1.611,
        'seasonalized volatility with news matches'
    );
};

subtest 'coefficients check' => sub {
    my $emp = BOM::MarketData::VolSurface::Empirical->new(underlying => $underlying);
    for (BOM::Market::UnderlyingDB->symbols_for_intraday_fx) {
        ok $emp->_get_coefficients('volatility_seasonality_coef', BOM::Market::Underlying->new($_)),
            'volatility seasonality coefficient defined ' . $_;
        ok $emp->_get_coefficients('duration_coef', BOM::Market::Underlying->new($_)), 'duration coefficient ' . $_;
    }
};
