#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 13;
use Test::NoWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use Format::Util::Numbers qw(roundnear);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMD qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

my $now = Date::Utility->new('2014-11-11');

BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'currency',
    {
        symbol => 'USD',
        recorded_date   => $now,
    });
BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'index',
    {
        symbol => 'R_100',
        recorded_date   => $now,
    });
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_100',
    epoch      => $now->epoch,
    quote      => 1000
});

my $params = {
    underlying => 'R_100',
    duration   => '5t',
    currency   => 'USD',
    payout     => 100,
    barrier    => 'S0P',
};

my $c = produce_contract({
    %$params,
    date_start   => $now,
    date_pricing => $now,
    bet_type     => 'FLASHU'
});
is $c->pricing_engine_name, 'Pricing::Engine::EuropeanDigitalSlope', 'correct pricing engine';
is roundnear(0.0001, $c->bs_probability->amount), 0.4994, 'bs probability is 0.5002';
is $c->total_markup->amount, 0.01, 'total markup is 0.01';

$c = produce_contract({
    %$params,
    date_start   => $now,
    date_pricing => $now,
    bet_type     => 'FLASHD',
});
is $c->pricing_engine_name, 'Pricing::Engine::EuropeanDigitalSlope', 'correct pricing engine';
is roundnear(0.0001, $c->bs_probability->amount), 0.5006, 'bs probability is 0.4998';
is $c->total_markup->amount, 0.01, 'total markup is 0.01';

$c = produce_contract({
    %$params,
    date_start   => $now,
    date_pricing => $now,
    bet_type     => 'ASIANU',
});
is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Asian', 'correct pricing engine';
is roundnear(0.0001, $c->bs_probability->amount), 0.4996, 'correct bs probability';
is $c->total_markup->amount, 0.015, 'correct total markup';

$c = produce_contract({
    %$params,
    date_start   => $now,
    date_pricing => $now,
    bet_type     => 'ASIAND',
});
is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Asian', 'correct pricing engine';
is roundnear(0.0001, $c->bs_probability->amount), 0.5004, 'correct bs probability';
is $c->total_markup->amount, 0.015, 'correct total markup';
