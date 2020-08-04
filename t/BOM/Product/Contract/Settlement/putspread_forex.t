#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Test::Exception;
use Test::MockModule;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Config::Chronicle;
use Quant::Framework;
use Finance::Exchange;

initialize_realtime_ticks_db();

my $now    = Date::Utility->new;
my $symbol = 'frxUSDJPY';
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

my $args = {
    bet_type     => 'PUTSPREAD',
    underlying   => $symbol,
    date_start   => $now,
    high_barrier => 'S10P',
    low_barrier  => 'S-10P',
    duration     => '5m',
    currency     => 'USD',
    payout       => 100,
};

my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader());
my $exchange         = Finance::Exchange->create_exchange('FOREX');
my $mock_date        = Test::MockModule->new('Date::Utility');
unless ($trading_calendar->is_open($exchange)) {
    $mock_date->mock(is_same_as => sub { 0 });
}

subtest 'intraday' => sub {
    subtest 'PUTSPREAD - exit tick higher than high barrier = zero payout' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,    $now->epoch + 1,   $symbol],
            [100.11, $now->epoch + 299, $symbol],
            [100,    $now->epoch + 301, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('5m')});
        is $c->entry_tick->quote,         100,       'entry tick is 100';
        is $c->high_barrier->as_absolute, '100.010', 'high barrier is 100.010';
        is $c->low_barrier->as_absolute,  '99.990',  'low barrier is 99.990';
        is $c->exit_tick->quote,          100.11,    'exit tick is 100.11';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'zero payout';
    };

    subtest 'PUTSPREAD - exit tick in between high and low barrier = partial payout' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,    $now->epoch + 1,   $symbol],
            [100.09, $now->epoch + 299, $symbol],
            [100,    $now->epoch + 301, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('5m')});
        is $c->entry_tick->quote,         100,       'entry tick is 100';
        is $c->high_barrier->as_absolute, '100.010', 'high barrier is 100.010';
        is $c->low_barrier->as_absolute,  '99.990',  'low barrier is 99.990';
        is $c->exit_tick->quote,          100.09,    'exit tick is 100.89';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'value less than payout';
    };

    subtest 'PUTSPREAD - exit tick is lower than low barrier = full payout' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,   $now->epoch + 1,   $symbol],
            [99.89, $now->epoch + 299, $symbol],
            [100,   $now->epoch + 301, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('5m')});
        is $c->entry_tick->quote,         100,       'entry tick is 100';
        is $c->high_barrier->as_absolute, '100.010', 'high barrier is 100.010';
        is $c->low_barrier->as_absolute,  '99.990',  'low barrier is 99.90';
        is $c->exit_tick->quote,          99.89,     'exit tick is 99.89';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, $c->payout, 'full payout';
    };
};

# this has to be a date in the past because of some quirks in getting OHLC in the future
$now                = Date::Utility->new('2019-03-04');
$args->{date_start} = $now;
$args->{duration}   = '1d';

done_testing();
