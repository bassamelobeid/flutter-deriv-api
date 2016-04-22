#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 5;
use Test::NoWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Market::Underlying;
use Date::Utility;

use BOM::Platform::Runtime;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

initialize_realtime_ticks_db;

my $weekday             = Date::Utility->new('2016-03-29');
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
    note('Testing date_start blackouts for frxUSDJPY');
    my $one_second_since_open = $weekday->plus_time_interval('1s');
    my $bet_params            = {
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        currency     => 'USD',
        payout       => 10,
        barrier      => 'S0P',
        date_pricing => $one_second_since_open,
        date_start   => $one_second_since_open,
        duration     => '6h',
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
    $c                          = produce_contract($bet_params);
    ok !$c->underlying->eod_blackout_start, 'no end of day blackout';
    ok $c->is_valid_to_buy, 'valid to buy';

    note('Testing date_start blackouts for HSI');
    my $hsi_open         = BOM::Market::Underlying->new('HSI')->calendar->opening_on($weekday);
    my $hsi_weekday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'HSI',
        epoch      => $hsi_open->epoch + 600,
        quote      => 7195,
    });
    $bet_params->{underlying}   = 'HSI';
    $bet_params->{current_tick} = $hsi_weekday_tick;
    $bet_params->{date_start}   = $bet_params->{date_pricing} = $hsi_open->epoch + 600;
    $bet_params->{duration}     = '1h';
    $c                          = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like(($c->primary_validation_error)[0]->{message_to_client}, qr/from 01:30:00 to 01:40:00/, 'throws error');
    $bet_params->{date_start} = $bet_params->{date_pricing} = $hsi_open->epoch + 601;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    my $hsi_close = BOM::Market::Underlying->new('HSI')->calendar->closing_on($weekday);
    $hsi_weekday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'HSI',
        epoch      => $hsi_close->epoch - 900,
        quote      => 7195,
    });
    $bet_params->{date_start} = $bet_params->{date_pricing} = $hsi_close->epoch - 900;
    $bet_params->{duration} = '15m';
    $bet_params->{current_tick} = $hsi_weekday_tick;
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_sell, 'not valid to buy';
    like(($c->primary_validation_error)[0]->{message_to_client}, qr/from 07:25:00 to 07:40:00/, 'throws error');

    note('Multiday contract on HSI');
    my $new_day           = $weekday->plus_time_interval('1d');
    my $hour_before_close = BOM::Market::Underlying->new('HSI')->calendar->closing_on($new_day)->minus_time_interval('1h');
    $hsi_weekday_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'HSI',
        epoch      => $hour_before_close->epoch,
        quote      => 7195,
    });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'HSI',
            recorded_date => $hour_before_close
        });
    $bet_params->{current_tick} = $hsi_weekday_tick;
    $bet_params->{date_start}   = $bet_params->{date_pricing} = $hour_before_close;
    $bet_params->{duration}     = '8d';
    $c                          = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{barrier} = 7200;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{duration} = '5d';
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like(($c->primary_validation_error)[0]->{message_to_client}, qr/from 06:40:00 to 07:40:00/, 'throws error');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $hour_before_close
        }) for qw(frxUSDJPY frxUSDHKD);
    $bet_params->{underlying} = 'frxUSDJPY';
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{date_start} = $bet_params->{date_pricing} = $hour_before_close->epoch - 1;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
};

subtest 'date_expiry blackouts' => sub {
    note('Testing date_expiry blackouts for HSI');
    my $new_week          = $weekday->plus_time_interval('7d');
    my $hsi_close         = BOM::Market::Underlying->new('HSI')->calendar->closing_on($new_week);
    my $hour_before_close = $hsi_close->minus_time_interval('1h');
    my $hsi_weekday_tick  = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'HSI',
        epoch      => $hour_before_close->epoch,
        quote      => 7195,
    });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'HSI',
            recorded_date => $hour_before_close
        });
    my $bet_params = {
        bet_type     => 'CALL',
        underlying   => 'HSI',
        date_start   => $hour_before_close,
        date_pricing => $hour_before_close,
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 10,
        duration     => '58m59s',
        current_tick => $hsi_weekday_tick,
    };
    my $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{duration} = '59m1s';
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like(($c->primary_validation_error)[0]->{message_to_client}, qr/between 07:39:00 and 07:40:00/, 'throws error');

    my $usdjpy_close = BOM::Market::Underlying->new('frxUSDJPY')->calendar->closing_on($new_week);
    my $pricing_date = $usdjpy_close->minus_time_interval('6h');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $pricing_date,
        }) for qw(frxUSDJPY frxUSDHKD);
    my $usdjpy_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $pricing_date->epoch,
    });
    $bet_params->{date_pricing} = $bet_params->{date_start} = $pricing_date;
    $bet_params->{duration}     = '5h59m1s';
    $bet_params->{underlying}   = 'frxUSDJPY';
    $bet_params->{current_tick} = $usdjpy_tick;
    $c                          = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
};

subtest 'date expiry blackout - year end holidays for equity' => sub {
    my $year_end   = Date::Utility->new('2016-12-30');
    my $date_start = BOM::Market::Underlying->new('HSI')->calendar->opening_on($year_end)->plus_time_interval('15m');
    my $tick       = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'HSI',
        epoch      => $date_start->epoch,
        quote      => 7195,
    });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'HSI',
            recorded_date => $date_start
        });
    my $bet_params = {
        bet_type     => 'CALL',
        underlying   => 'HSI',
        date_start   => $date_start,
        date_pricing => $date_start,
        barrier      => 'S10P',
        currency     => 'USD',
        payout       => 10,
        duration     => '5d',
        current_tick => $tick,
    };
    my $c = produce_contract($bet_params);
    ok !$c->is_atm_bet,      'not ATM contract';
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like($c->primary_validation_error->message_to_client, qr/not expire between 2016-12-30 and 2017-01-05/, 'throws error');
    $bet_params->{barrier} = 'S0P';
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy for ATM';
    $bet_params->{barrier}  = 'S10P';
    $bet_params->{duration} = '7d';
    $c                      = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy for non ATM past holiday blackout period';
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $date_start
        }) for qw(frxUSDJPY frxUSDHKD);
    $bet_params->{underlying} = 'frxUSDJPY';
    $bet_params->{duration}   = '5d';
    $c                        = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy for Forex during holiday blackout period';
};

subtest 'market_risk blackouts' => sub {
    note('Testing inefficient periods for frxXAUUSD');
    my $inefficient_period = $weekday->plus_time_interval('20h59m59s');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => 'XAU',
            recorded_date => $inefficient_period->minus_time_interval('1h')});
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol        => 'frxXAUUSD',
            recorded_date => $inefficient_period->minus_time_interval('1h')});
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $inefficient_period->minus_time_interval('1h'),
        }) for qw(frxXAUUSD);
    my $xauusd_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxXAUUSD',
        epoch      => $inefficient_period->minus_time_interval('1h')->epoch,
    });
    my $bet_params = {
        bet_type     => 'CALL',
        underlying   => 'frxXAUUSD',
        date_start   => $inefficient_period->minus_time_interval('1h'),
        date_pricing => $inefficient_period->minus_time_interval('1h'),
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 10,
        duration     => '59m59s',
        current_tick => $xauusd_tick,
    };
    my $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{date_start} = $bet_params->{date_pricing} = $inefficient_period;
    $bet_params->{duration}   = '15m';
    $xauusd_tick              = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxXAUUSD',
        epoch      => $inefficient_period->epoch,
    });
    $bet_params->{current_tick} = $xauusd_tick;
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like(($c->primary_validation_error)[0]->{message_to_client}, qr/from 21:00:00 to 23:59:59/, 'throws error');
};
