#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::Warnings qw/warning/;
use Test::MockModule;
use YAML::XS qw(LoadFile);
use Date::Utility;

use LandingCompany::Offerings qw(reinitialise_offerings);

use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Market::DataDecimate;

reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);

my $ticks = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/ticks.yml');

my $mocked = Test::MockModule->new('BOM::Market::DataDecimate');

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
    barrier      => 'S10P',
    currency     => 'USD',
};

subtest 'no ticks in decimate ticks' => sub {
    $mocked->mock('decimate_cache_get', sub { [] });
    my $c = produce_contract($contract_args);
    my $args;
    warning { $args = $c->pricing_args }, qr/No basis tick for/;
    my $res;
    warning { $res = $c->pricing_vol }, qr/No basis tick for/;
    is $res, $args->{long_term_prediction}, 'we rely solely on long term prediction if there is no decimated ticks.';
    warning { $res = $c->pricing_engine->risk_markup->peek_amount('vol_spread') }, qr/No basis tick for/;
    is $res, 0.05, 'charged a 10% vol spread markup due to shortterm uncertainty';
};

subtest 'one tick in decimate ticks' => sub {
    $mocked->mock('decimate_cache_get', sub { [$ticks->[0]] });
    my $c = produce_contract($contract_args);
    my $args;
    warning { $args = $c->pricing_args }, qr/No basis tick for/;
    my $res;
    warning { $res = $c->pricing_vol }, qr/No basis tick for/;
    is $res, $args->{long_term_prediction}, 'we rely solely on long term prediction if there is only one decimated tick.';
    warning { $res = $c->pricing_engine->risk_markup->peek_amount('vol_spread') }, qr/No basis tick for/;
    is $res, 0.05, 'charged a 10% vol spread markup due to shortterm uncertainty';
};

subtest 'ten ticks in decimate ticks' => sub {
    $mocked->mock(
        'decimate_cache_get',
        sub {
            [map { $ticks->[$_] } (0 .. 9)];
        });
    my $c = produce_contract($contract_args);
    my $args;
    warning { $args = $c->pricing_args }, qr/No basis tick for/;
    my $res;
    warning { $res = $c->pricing_vol }, qr/No basis tick for/;
    is $res, 0.119418941965231, 'we rely solely on long term prediction if there is only one decimated tick.';
    is $args->{volatility_scaling_factor}, 135 / 1800, 'scaling factor is non zero';
    warning { $res = $c->pricing_engine->risk_markup->peek_amount('vol_spread') }, qr/No basis tick for/;
    is $res, 0.04971875, 'charged a 9.9 vol spread markup due to shortterm uncertainty';
};

subtest 'full set of decimate ticks' => sub {
    $mocked->mock('decimate_cache_get', sub { $ticks });
    my $c = produce_contract($contract_args);
    my $args;
    warning { $args = $c->pricing_args }, qr/No basis tick for/;
    my $res;
    warning { $res = $c->pricing_vol }, qr/No basis tick for/;
    is $res, 0.106236103095101, 'we rely solely on long term prediction if there is only one decimated tick.';
    is $args->{volatility_scaling_factor}, 1, 'scaling factor is 1';
    warning { $res = $c->pricing_engine->risk_markup->peek_amount('vol_spread_markup') }, qr/No basis tick for/;
    is $res, 0, 'charged a 0% vol spread markup when we have full set of ticks to calculate volatility';
    $contract_args->{barrier} = 'S0P';
    $c = produce_contract($contract_args);
    warning { $res = $c->pricing_engine->risk_markup->peek_amount('vol_spread_markup') }, qr/No basis tick for/;
    ok !$res, 'vol_spread_markup undef for atm contract';
};
done_testing();
