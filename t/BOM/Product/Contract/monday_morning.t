#!/usr/bin/perl

use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Product::ContractFactory qw(produce_contract);
use Test::More;
use Test::MockModule;
use Test::Warn;
use Test::Warnings;
use Date::Utility;

subtest 'monday mornings intraday' => sub {
    my $mocked = Test::MockModule->new('BOM::Market::DataDecimate');
    my $dp = Date::Utility->new('2017-06-13 00:19:59');
    my $args = {
        bet_type => 'CALL',
        underlying => 'frxUSDJPY',
        date_start => $dp,
        date_pricing => $dp,
        duration => '1h',
        barrier => 'S0P',
        currency => 'USD',
        payout => 100,
    };
    my $c = produce_contract($args);
    isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';
    my $vol;
    warning_like { $vol = $c->pricing_engine->_calculate_historical_volatility} qr/Historical ticks not found/, 'warn if historical tick not found after first 20 minutes of a tuesday';
    $dp = Date::Utility->new('2017-06-12 00:19:59');
    $args->{date_pricing} = $args->{date_start} = $dp;
    $c = produce_contract($args);
    is $c->pricing_engine->_calculate_historical_volatility, 0.1, '10% vol on monday morning before first 20 minutes';
    $dp = Date::Utility->new('2017-06-12 00:20:01');
    $args->{date_pricing} = $args->{date_start} = $dp;
    $c = produce_contract($args);
    warning_like {$c->pricing_engine->_calculate_historical_volatility} qr/Historical ticks not found/, 'warn if historical tick not found after first 20 minutes of a monday morning';
    $mocked->mock('get', sub {[map {{epoch => $_, decimate_epoch => $_, quote => 100 + rand(0.1)}} (0..10)]});
    warning_like {$c->pricing_engine->_calculate_historical_volatility} qr/Historical ticks not found/, 'warn if historical tick is not sufficient';
    $mocked->mock('get', sub {[map {{epoch => $_, decimate_epoch => $_, quote => 100 + rand(0.1)}} (0..80)]});
    ok $c->pricing_engine->_calculate_historical_volatility, 'no warnings';
};

done_testing();
