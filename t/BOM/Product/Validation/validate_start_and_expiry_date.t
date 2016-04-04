#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::NoWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Market::Underlying;
use Date::Utility;

use BOM::Platform::Runtime;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

initialize_realtime_ticks_db;

my $weekday = Date::Utility->new('2016-03-29');
my $usdjpy_weekday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $weekday->epoch
});
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

subtest 'date start blackouts' => sub {
    note ('Testing date_start blackouts for frxUSDJPY');
    my $one_second_since_open = $weekday->plus_time_interval('1s');
    my $bet_params = {
        bet_type => 'CALL',
        underlying => 'frxUSDJPY',
        currency => 'USD',
        payout => 10,
        barrier => 'S0P',
        date_pricing => $one_second_since_open,
        date_start => $one_second_since_open,
        duration => '6h',
        current_tick => $usdjpy_weekday_tick,
    };
    my $c = produce_contract($bet_params);
    ok !$c->underlying->sod_blackout_start, 'no start of day blackout';
    ok $c->is_valid_to_buy, 'valid to buy';
    my $one_second_before_close = $weekday->plus_time_interval('1d')->minus_time_interval('1s');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $one_second_before_close,
        }) for qw(frxUSDJPY frxUSDHKD);
    $usdjpy_weekday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $one_second_before_close->epoch
    });
    $bet_params->{date_pricing} = $bet_params->{date_start} = $one_second_before_close;
    $bet_params->{current_tick} = $usdjpy_weekday_tick;
    $c = produce_contract($bet_params);
    ok !$c->underlying->eod_blackout_start, 'no end of day blackout';
    ok $c->is_valid_to_buy, 'valid to buy';

    note ('Testing date_start blackouts for frxUSDJPY');
    my $hsi_open = BOM::Market::Underlying->new('HSI')->exchange->opening_on($weekday);
    my $hsi_weekday_tick  = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'HSI',
        epoch      => $hsi_open->epoch + 600,
        quote => 7195,
    });
    $bet_params->{underlying} = 'HSI';
    $bet_params->{current_tick} = $hsi_weekday_tick;
    $bet_params->{date_start} = $bet_params->{date_pricing} = $hsi_open->epoch + 600;
    $bet_params->{duration} = '1h';
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like (($c->primary_validation_error)[0]->{message_to_client}, qr/from 01:30:00 to 01:40:00/, 'throws error');
    $bet_params->{date_start} = $bet_params->{date_pricing} = $hsi_open->epoch + 601;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    my $hsi_close = BOM::Market::Underlying->new('HSI')->exchange->closing_on($weekday);
    $hsi_weekday_tick  = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'HSI',
        epoch      => $hsi_close->epoch - 900,
        quote => 7195,
    });
    $bet_params->{date_start} = $bet_params->{date_pricing} = $hsi_close->epoch - 900;
    $bet_params->{duration} = '15m';
    $bet_params->{current_tick} = $hsi_weekday_tick;
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_sell, 'not valid to buy';
    like (($c->primary_validation_error)[0]->{message_to_client}, qr/from 07:25:00 to 07:40:00/, 'throws error');
};
