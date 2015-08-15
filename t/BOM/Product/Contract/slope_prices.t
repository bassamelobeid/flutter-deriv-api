#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 11;

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;
use Format::Util::Numbers qw(roundnear);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

initialize_realtime_ticks_db();

my $now = Date::Utility->new('2014-11-11');

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol => 'FOREX',
        date   => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => $_,
        date   => $now,
    }) for (qw/JPY USD JPY-USD/);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now,
        surface       => {
            7 => {
                smile => {
                    25 => 0.099,
                    50 => 0.1,
                    75 => 0.11
                },
                vol_spread => {50 => 0.01}
            },
            14 => {
                smile => {
                    25 => 0.099,
                    50 => 0.1,
                    75 => 0.11
                },
                vol_spread => {50 => 0.01}
            },
        },
    });

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch - 3600,
    quote      => 100
});

# forward starting
my $params = {
    bet_type     => 'INTRADU',
    underlying   => 'frxUSDJPY',
    date_start   => $now,
    date_pricing => $now->epoch - 3600,
    duration     => '15m',
    currency     => 'USD',
    barrier      => 'S0P',
    payout       => 100,
};

my $c = produce_contract($params);
is $c->bs_probability->amount, 0.500099930268069, 'correct bs probability';
is roundnear(0.0001, $c->pricing_engine->skew_adjustment->amount), 0.0035, 'correct skew adjustment';
is roundnear(0.0001, $c->total_markup->amount),    0.0163, 'correct total markup';
is roundnear(0.0001, $c->ask_probability->amount), 0.5199, 'correct ask probability';

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol => 'EURONEXT',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'index',
    {
        symbol => 'AEX',
        date   => $now,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => 'EUR',
        date   => $now,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'AEX',
        recorded_date => $now,
    });
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'AEX',
    epoch      => $now->epoch - 3600,
    quote      => 100
});

$c = produce_contract({
    %$params,
    underlying => 'AEX',
    currency   => 'EUR',
});
is $c->bs_probability->amount, 0.499086543543306, 'correct bs probability';
is $c->pricing_engine->skew_adjustment->amount, 0, 'zero skew adjustment';
is $c->total_markup->amount, 0.03, 'total markup is 3%';

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency_config',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for qw( JPY USD );

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch,
    quote      => 100
});
delete $params->{date_pricing};
$c = produce_contract({
    %$params,
    underlying   => 'frxUSDJPY',
    date_pricing => $now,
    bet_type     => 'CALL',
    duration     => '10d',
});
is $c->bs_probability->amount, 0.503170070758588, 'correct bs probability';
is roundnear(0.0001, $c->pricing_engine->skew_adjustment->amount), 0.0333, 'correct skew adjustment';
is roundnear(0.0001, $c->total_markup->amount),    0.0242, 'correct total markup';
is roundnear(0.0001, $c->ask_probability->amount), 0.5608, 'correct ask probability';
1;
