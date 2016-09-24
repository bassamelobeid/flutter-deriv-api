#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::MockModule;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;
use BOM::Market::AggTicks;
use BOM::Market::Underlying;

my $now = Date::Utility->new('2016-09-22 20:00:00');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now->minus_time_interval('1s')});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now->minus_time_interval('1s')}) for qw(USD JPY JPY-USD);
my $start = $now->epoch - 300;

subtest 'spot drops' => sub {
    my $mocked = Test::MockModule->new('BOM::Market::AggTicks');
    $mocked->mock(
        'retrieve',
        sub {
            [map { {epoch => $_, quote => 100 + int(rand(2)), symbol => 'frxUSDJPY'} } ($start .. $now->epoch)];
        });
    my $fake_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $now->epoch,
        quote      => 70
    });
    my $params = {
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        date_start   => $now,
        date_pricing => $now,
        duration     => '5m',
        current_tick => $fake_tick,
        currency     => 'USD',
        payout       => 100,
        barrier      => 'S0P',
    };
    my $c = produce_contract($params);
    ok $c->ask_price, 'can get a price';
    ok $c->pricing_engine->risk_markup->peek_amount('spot_jump_markup'), 'spot_jump_markup is applied';
    $params->{date_start} = $params->{date_pricing} = $now->epoch - 1;
    note('set time to 19:59:59');
    $c = produce_contract($params);
    ok $c->ask_price, 'can get a price';
    ok !$c->pricing_engine->risk_markup->peek_amount('spot_jump_markup'),
        'spot_jump_markup is not applied if date pricing is not in inefficient period';
    note('set time to 20:00:00');
    $params->{date_start} = $params->{date_pricing} = $now->epoch;
    $params->{bet_type}   = 'PUT';
    $c                    = produce_contract($params);
    ok $c->ask_price, 'can get a price';
    ok !$c->pricing_engine->risk_markup->peek_amount('spot_jump_markup'), 'spot_jump_markup is not applied';
};

subtest 'spot increases' => sub {
    my $mocked = Test::MockModule->new('BOM::Market::AggTicks');
    $mocked->mock(
        'retrieve',
        sub {
            [map { {epoch => $_, quote => 100 + int(rand(2)), symbol => 'frxUSDJPY'} } ($start .. $now->epoch)];
        });
    my $fake_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $now->epoch + 1,
        quote      => 130
    });
    my $params = {
        bet_type     => 'PUT',
        underlying   => 'frxUSDJPY',
        date_start   => $now,
        date_pricing => $now,
        duration     => '5m',
        current_tick => $fake_tick,
        currency     => 'USD',
        payout       => 100,
        barrier      => 'S0P',
    };
    my $c = produce_contract($params);
    ok $c->ask_price, 'can get a price';
    ok $c->pricing_engine->risk_markup->peek_amount('spot_jump_markup'), 'spot_jump_markup is applied';
    $params->{bet_type} = 'CALL';
    $c = produce_contract($params);
    ok $c->ask_price, 'can get a price';
    ok !$c->pricing_engine->risk_markup->peek_amount('spot_jump_markup'), 'spot_jump_markup is not applied';
};

done_testing();
