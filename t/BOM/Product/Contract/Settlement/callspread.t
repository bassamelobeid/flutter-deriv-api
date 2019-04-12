#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Test::Exception;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory qw(produce_contract);

initialize_realtime_ticks_db();

my $now    = Date::Utility->new;
my $symbol = 'R_100';
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

my $args = {
    bet_type     => 'CALLSPREAD',
    underlying   => $symbol,
    date_start   => $now,
    high_barrier => 'S10P',
    low_barrier  => 'S-10P',
    duration     => '5m',
    currency     => 'USD',
    payout       => 100,
};

subtest 'intraday' => sub {
    subtest 'CALLSPREAD - exit tick higher than high barrier = full payout' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,    $now->epoch + 1,   $symbol],
            [100.11, $now->epoch + 299, $symbol],
            [100,    $now->epoch + 301, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('5m')});
        is $c->entry_tick->quote,         100,      'entry tick is 100';
        is $c->high_barrier->as_absolute, '100.10', 'high barrier is 100.10';
        is $c->low_barrier->as_absolute,  '99.90',  'low barrier is 99.90';
        is $c->exit_tick->quote,          100.11,   'exit tick is 100.11';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, $c->payout, 'win';
    };

    subtest 'CALLSPREAD - exit tick in between high and low barrier = partial payout' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,    $now->epoch + 1,   $symbol],
            [100.09, $now->epoch + 299, $symbol],
            [100,    $now->epoch + 301, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('5m')});
        is $c->entry_tick->quote,         100,      'entry tick is 100';
        is $c->high_barrier->as_absolute, '100.10', 'high barrier is 100.10';
        is $c->low_barrier->as_absolute,  '99.90',  'low barrier is 99.90';
        is $c->exit_tick->quote,          100.09,   'exit tick is 100.89';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 95.0000000000043, 'value less than payout';
    };

    subtest 'CALLSPREAD - exit tick is lower than low barrier = zero payout' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,   $now->epoch + 1,   $symbol],
            [99.89, $now->epoch + 299, $symbol],
            [100,   $now->epoch + 301, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('5m')});
        is $c->entry_tick->quote,         100,      'entry tick is 100';
        is $c->high_barrier->as_absolute, '100.10', 'high barrier is 100.10';
        is $c->low_barrier->as_absolute,  '99.90',  'low barrier is 99.90';
        is $c->exit_tick->quote,          99.89,    'exit tick is 99.89';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'zero payout';
    };
};

# this has to be a date in the past because of some quirks in getting OHLC in the future
$now                = Date::Utility->new('2019-03-04');
$args->{date_start} = $now;
$args->{duration}   = '1d';

subtest 'multiday' => sub {
    subtest 'CALLSPREAD - expired but no OHLC data' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100, $now->epoch + 1,                                                 $symbol],
            [102, $now->epoch + 2,                                                 $symbol],
            [100, $now->truncate_to_day->plus_time_interval('1d23h59m59s')->epoch, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $args->{date_start}->truncate_to_day->plus_time_interval('1d23h59m59s')->epoch});
        ok $c->expiry_daily, 'multi-day contract';
        ok $c->is_expired,   'is expired';
        is $c->exit_tick->quote, 100, 'exit tick is 100';
        ok !$c->is_valid_to_sell, 'not valid to sell';
        is $c->primary_validation_error->message, 'exit tick is inconsistent';
        ok $c->waiting_for_settlement_tick, 'waiting for settlement tick';
        ok !$c->require_manual_settlement, 'does not require manual settlement';
    };

    subtest 'CALLSPREAD - expired with OHLC data' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::create_ohlc_daily({
            underlying => $symbol,
            epoch      => $args->{date_start}->truncate_to_day->plus_time_interval('1d')->epoch,
            open       => 100,
            high       => 101,
            low        => 99,
            close      => 100.11,
            official   => 0,
        });
        my $c = produce_contract({%$args, date_pricing => $args->{date_start}->truncate_to_day->plus_time_interval('1d23h59m59s')->epoch});
        ok $c->expiry_daily, 'multi-day contract';
        is $c->high_barrier->as_absolute, '100.10', 'high barrier is 100.10';
        is $c->low_barrier->as_absolute,  '99.90',  'low barrier is 99.90';
        is $c->exit_tick->quote,          100.11,   'exit tick is 100.11';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, $c->payout, 'win';
    };
};

done_testing();
