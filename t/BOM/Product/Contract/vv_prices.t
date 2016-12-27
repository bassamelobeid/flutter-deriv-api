#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 12;
use Test::FailWarnings;

use BOM::Product::ContractFactory qw(produce_contract);

use Date::Utility;
use Format::Util::Numbers qw(roundnear);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

my $now = Date::Utility->new('2014-11-11');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        rates  => {
            8 => 0,
            0 => 0
        },
        recorded_date => $now,
    }) for (qw/JPY USD JPY-USD/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now,
        surface       => {
            7 => {
                smile => {
                    25 => 0.09,
                    50 => 0.1,
                    75 => 0.11
                },
                vol_spread => {50 => 0.01}
            },
            8 => {
                smile => {
                    25 => 0.09,
                    50 => 0.1,
                    75 => 0.11
                },
                vol_spread => {50 => 0.01}
            },
            14 => {
                smile => {
                    25 => 0.09,
                    50 => 0.1,
                    75 => 0.11
                },
                vol_spread => {50 => 0.01}
            },
        }});

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch - 2,
    quote      => 100
});

my $params = {
    bet_type     => 'ONETOUCH',
    underlying   => 'frxUSDJPY',
    date_start   => $now,
    date_pricing => $now,
    duration     => '7d',
    currency     => 'USD',
    barrier      => 98,
};
my $c = produce_contract($params);
like $c->pricing_engine_name, qr/VannaVolga/, 'VV engine selected';
is roundnear(0.0001, $c->pricing_engine->bs_probability->amount), 0.1537, 'correct bs probability for FX contract';
is roundnear(0.0001, $c->pricing_engine->market_supplement->amount), 0.0355, 'correct market supplement';

$c = produce_contract({
    %$params,
    bet_type     => 'RANGE',
    high_barrier => 101,
    low_barrier  => 99,
});
like $c->pricing_engine_name, qr/VannaVolga/, 'VV engine selected';
is roundnear(0.0001, $c->pricing_engine->bs_probability->amount), 0.1053, 'correct bs probability for FX contract';
is roundnear(0.0001, $c->pricing_engine->market_supplement->amount), 0.0287, 'correct market supplement';

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => 'AEX',
        recorded_date => Date::Utility->new($params->{date_pricing}),
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'EUR',
        recorded_date => $now,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'AEX',
        recorded_date => $now,
    });
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'AEX',
    epoch      => $now->epoch,
    quote      => 100
});

$c = produce_contract({
    %$params,
    underlying => 'AEX',
    currency   => 'EUR',
});
like $c->pricing_engine_name, qr/VannaVolga/, 'VV engine selected';
is roundnear(0.0001, $c->pricing_engine->bs_probability->amount), 0.6241, 'correct bs probability for indices contract';
is roundnear(0.0001, $c->pricing_engine->market_supplement->amount), -0.0247, 'correct market supplement';

$c = produce_contract({
    %$params,
    bet_type     => 'RANGE',
    high_barrier => 105.1,
    low_barrier  => 97.8,
    underlying   => 'AEX',
    currency     => 'EUR',
});
like $c->pricing_engine_name, qr/VannaVolga/, 'VV engine selected';
is roundnear(0.0001, $c->pricing_engine->bs_probability->amount), 0.2154, 'correct bs probability for indices contract';
is roundnear(0.0001, $c->pricing_engine->market_supplement->amount), 0.0139, 'correct market supplement';
