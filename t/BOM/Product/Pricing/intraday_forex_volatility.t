#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use Test::MockModule;
use YAML::XS qw(LoadFile);
use Date::Utility;
use BOM::Product::ContractFactory qw( produce_contract );

use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

use BOM::Market::DecimateCache;

my $ticks = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/ticks.yml');

my $mocked = Test::MockModule->new('BOM::Market::DecimateCache');

my $now = Date::Utility->new('2016-08-05 12:00:00');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(USD JPY JPY-USD);

my $contract_args = {
    bet_type     => 'CALL',
    underlying   => 'frxUSDJPY',
    duration     => '30m',
    date_start   => $now,
    date_pricing => $now,
    barrier      => 'S0P',
    currency     => 'USD',
};

subtest 'no ticks in decimate ticks' => sub {
    $mocked->mock('decimate_cache_get', sub { [] });
    my $c = produce_contract($contract_args);
    $c->pricing_args;
    is $c->pricing_vol, $c->pricing_args->{long_term_prediction}, 'we rely solely on long term prediction if there is no decimated ticks.';
    is $c->pricing_engine->risk_markup->peek_amount('vol_spread'), 0.05, 'charged a 10% vol spread markup due to shortterm uncertainty';
};

subtest 'one tick in decimate ticks' => sub {
    $mocked->mock('decimate_cache_get', sub { [$ticks->[0]] });
    my $c = produce_contract($contract_args);
    $c->pricing_args;
    is $c->pricing_vol, $c->pricing_args->{long_term_prediction}, 'we rely solely on long term prediction if there is only one decimated tick.';
    is $c->pricing_engine->risk_markup->peek_amount('vol_spread'), 0.05, 'charged a 10% vol spread markup due to shortterm uncertainty';
};

subtest 'ten ticks in decimate ticks' => sub {
    $mocked->mock(
        'decimate_cache_get',
        sub {
            [map { $ticks->[$_] } (0 .. 9)];
        });
    my $c = produce_contract($contract_args);
    $c->pricing_args;
    is $c->pricing_vol, 0.118725511279854, 'we rely solely on long term prediction if there is only one decimated tick.';
    is $c->pricing_args->{volatility_scaling_factor}, 135 / 1800, 'scaling factor is non zero';
    is $c->pricing_engine->risk_markup->peek_amount('vol_spread'), 0.04971875, 'charged a 9.9 vol spread markup due to shortterm uncertainty';
};

subtest 'full set of decimate ticks' => sub {
    $mocked->mock('decimate_cache_get', sub { $ticks });
    my $c = produce_contract($contract_args);
    $c->pricing_args;
    is $c->pricing_vol, 0.105908540749393, 'we rely solely on long term prediction if there is only one decimated tick.';
    is $c->pricing_args->{volatility_scaling_factor}, 1, 'scaling factor is 1';
    is $c->pricing_engine->risk_markup->peek_amount('vol_spread_markup'), 0,
        'charged a 0% vol spread markup when we have full set of ticks to calculate volatility';
};
done_testing();
