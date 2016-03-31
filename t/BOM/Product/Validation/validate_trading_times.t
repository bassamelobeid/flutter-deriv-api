#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::NoWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Market::Underlying;
use Date::Utility;

use BOM::Platform::Runtime;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

my $weekend = Date::Utility->new('2016-03-26');
my $weekday = Date::Utility->new('2016-03-29');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $weekday
    }) for qw(USD JPY HKD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => 'HSI',
        recorded_date => $weekday
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $weekday
    }) for qw(frxUSDJPY frxUSDHKD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'HSI',
        recorded_date => $weekday
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'correlation_matrix',
    {
        recorded_date => $weekday,
        symbol        => 'indices',
        correlations  => {
            'HSI' => {
                USD => {
                    '3M'  => 0.1,
                    '12M' => 0.1
                },
                GBP => {
                    '3M'  => 0.1,
                    '12M' => 0.1
                },
                AUD => {
                    '3M'  => 0.1,
                    '12M' => 0.1
                },
                EUR => {
                    '3M'  => 0.1,
                    '12M' => 0.1
                },
            }}});

subtest 'trading hours' => sub {
    my $usdjpy_weekend_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $weekend->epoch
    });
    my $usdjpy_weekday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $weekday->epoch
    });
    my $args = {
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        barrier      => 'S0P',
        date_start   => $weekday,
        date_pricing => $weekday,
        duration     => '6h',
        currency     => 'USD',
        payout       => 10,
        current_tick => $usdjpy_weekday_tick,
    };

    my $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';
    $args->{date_start} = $args->{date_pricing} = $weekend;
    $args->{current_tick} = $usdjpy_weekend_tick;
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like(($c->primary_validation_error)[0]->{message_to_client}, qr/market is presently/, 'throws error message');

    my $hsi_open         = $weekday->plus_time_interval('1h30m');
    my $hsi_time         = $hsi_open->plus_time_interval('11m');
    my $hsi_weekday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'HSI',
        epoch      => $hsi_time->epoch,
        quote      => 7150
    });
    $args->{underlying}   = 'HSI';
    $args->{date_start}   = $args->{date_pricing} = $hsi_time;
    $args->{current_tick} = $hsi_weekday_tick;
    $args->{duration}     = '1h';
    $c                    = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';
    $args->{date_start} = $args->{date_pricing} = $hsi_time->minus_time_interval('22m');
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like(($c->primary_validation_error)[0]->{message_to_client}, qr/market is presently/, 'throws error message');

    # for forward starting
    $args->{date_pricing} = $hsi_open->minus_time_interval('20m');
    $args->{date_start}   = $hsi_open->minus_time_interval('10m');
    $c                    = produce_contract($args);
    ok $c->is_forward_starting, 'forward starting';
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like(($c->primary_validation_error)[0]->{message_to_client}, qr/market must be open at the start time/, 'throws error message');
    $args->{date_start} = $hsi_open->plus_time_interval('11m');
    $c = produce_contract($args);
    ok $c->is_forward_starting, 'forward starting';
    ok $c->is_valid_to_buy,     'valid to buy';

    my $valid_start = $hsi_open->plus_time_interval('2h');
    $args->{date_start} = $args->{date_pricing} = $valid_start;
    $args->{duration}   = '1h';
    $hsi_weekday_tick   = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'HSI',
        epoch      => $valid_start->epoch,
        quote      => 7150
    });
    $args->{current_tick} = $hsi_weekday_tick;
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like(($c->primary_validation_error)[0]->{message_to_client}, qr/must expire during trading hours/, 'throws error message');
};
