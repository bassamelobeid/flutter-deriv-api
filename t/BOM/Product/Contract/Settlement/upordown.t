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
    bet_type     => 'UPORDOWN',
    underlying   => $symbol,
    date_start   => $now,
    high_barrier => 'S10P',
    low_barrier  => 'S-10P',
    duration     => '5m',
    currency     => 'USD',
    payout       => 100,
};

subtest 'intraday' => sub {
    subtest 'UPORDOWN - not expired 1 second before expiry' => sub {
        my $c = produce_contract({%$args, date_pricing => $args->{date_start}->plus_time_interval($args->{duration})->minus_time_interval('1s')});
        ok !$c->is_expired, 'not expired';
    };

    subtest 'UPORDOWN - not ok through expiry' => sub {
        my $mocked_c = Test::MockModule->new('BOM::Product::Contract::Upordown');
        $mocked_c->mock('_ohlc_for_contract_period', sub { return {high => 100, low => 99, close => 100} });
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100, $now->epoch + 1,   $symbol],
            [99.91,  $now->epoch + 2,   $symbol],
            [100, $now->epoch + 301, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $args->{date_start}->plus_time_interval($args->{duration} . '1s')});
        ok $c->is_expired, 'is expired';
        is $c->high_barrier->as_absolute, '100.10', 'high barrier is 100.10';
        is $c->low_barrier->as_absolute, '99.90', 'low barrier is 99.90';
        ok !$c->ok_through_expiry, 'not ok through expiry';
        ok !$c->is_valid_to_sell,  'not valid to sell';
        ok !$c->hit_tick,          'no hit tick';
        is $c->primary_validation_error->message, 'inconsistent close for period';
        ok $c->waiting_for_settlement_tick, 'waiting for settlement tick';
        ok !$c->require_manual_settlement, 'does not require manual settlement';
    };

    subtest 'UPORDOWN - Does not touch the barrier and ok through expiry. Contract will be settled as a loss.' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100, $now->epoch + 1,                         $symbol],
            [99.91,  $now->epoch + 2,                         $symbol],
            [100, $now->plus_time_interval('5m1s')->epoch, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $args->{date_start}->plus_time_interval($args->{duration} . '1s')});
        ok $c->is_expired,        'is expired';
        is $c->high_barrier->as_absolute, '100.10', 'high barrier is 100.10';
        is $c->low_barrier->as_absolute, '99.90', 'low barrier is 99.90';
        ok $c->ok_through_expiry, 'ok through expiry';
        ok !$c->hit_tick, 'no hit tick';
        ok $c->is_valid_to_sell, 'valid to sell';
        is $c->value, 0, 'loss';
    };

    subtest 'UPORDOWN - tick touches high barrier before expiry. Contract will be settled as a win' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,   $now->epoch + 1,                         $symbol],
            [100.1, $now->epoch + 2,                         $symbol],
            [100,   $now->plus_time_interval('5m1s')->epoch, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $args->{date_start}->plus_time_interval('2s')});
        ok $c->is_expired, 'is expired';
        is $c->high_barrier->as_absolute, '100.10', 'high barrier is 100.10';
        is $c->low_barrier->as_absolute, '99.90', 'low barrier is 99.90';
        ok !$c->ok_through_expiry, 'not ok through expiry';
        is $c->hit_tick->quote, 100.1, 'hit tick is 100.1';
        ok $c->is_valid_to_sell, 'valid to sell';
        is $c->value, $c->payout, 'win';
    };

    subtest 'UPORDOWN - tick touches low barrier before expiry. Contract will be settled as a win' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,   $now->epoch + 1,                         $symbol],
            [99.90, $now->epoch + 2,                         $symbol],
            [100,   $now->plus_time_interval('5m1s')->epoch, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $args->{date_start}->plus_time_interval('2s')});
        ok $c->is_expired, 'is expired';
        is $c->high_barrier->as_absolute, '100.10', 'high barrier is 100.10';
        is $c->low_barrier->as_absolute, '99.90', 'low barrier is 99.90';
        ok !$c->ok_through_expiry, 'not ok through expiry';
        is $c->hit_tick->quote, 99.9, 'hit tick is 99.9';
        ok $c->is_valid_to_sell, 'valid to sell';
        is $c->value, $c->payout, 'win';
    };
};

# this has to be a date in the past because of some quirks in getting OHLC in the future
$now                = Date::Utility->new('2019-03-04');
$args->{date_start} = $now;
$args->{duration}   = '1d';

subtest 'multiday' => sub {
    subtest 'UPORDOWN - expired but no OHLC data' => sub {
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

    subtest 'UPORDOWN - expired with OHLC data' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::create_ohlc_daily({
            underlying => $symbol,
            epoch      => $args->{date_start}->truncate_to_day->plus_time_interval('1d')->epoch,
            open       => 100,
            high       => 101,
            low        => 99,
            close      => 100,
            official   => 0,
        });
        my $c = produce_contract({%$args, date_pricing => $args->{date_start}->truncate_to_day->plus_time_interval('1d23h59m59s')->epoch});
        ok $c->expiry_daily, 'multi-day contract';
        ok $c->is_expired,   'is expired';
        is $c->hit_tick->quote, 102, 'hit tick is 102';
        ok $c->ok_through_expiry, 'ok through expiry';
        ok $c->is_valid_to_sell,  'valid to sell';
        ok !$c->waiting_for_settlement_tick, 'waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, $c->payout, 'win - because high > barrier';
    };
};

done_testing();
