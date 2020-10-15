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
    bet_type   => 'CALL',
    underlying => $symbol,
    date_start => $now,
    barrier    => 'S0P',
    duration   => '1t',
    currency   => 'USD',
    payout     => 100,
};

subtest 'tick expiry' => sub {
    subtest 'CALL - exit tick higher than entry tick will be settled as win' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch + 1, $symbol], [101, $now->epoch + 2, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('2s')});
        ok $c->entry_tick,       'entry tick is defined';
        ok $c->exit_tick,        'exit tick is defined';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, $c->payout, 'win';
    };

    subtest 'CALL - exit tick equal to entry tick will be settled as loss' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch + 1, $symbol], [100, $now->epoch + 2, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('2s')});
        ok $c->entry_tick,       'entry tick is defined';
        ok $c->exit_tick,        'exit tick is defined';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'loss';
    };

    subtest 'CALL - exit tick lower to entry tick will be settled as loss' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch + 1, $symbol], [99, $now->epoch + 2, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('2s')});
        ok $c->entry_tick,       'entry tick is defined';
        ok $c->exit_tick,        'exit tick is defined';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'loss';
    };
};

$args->{duration} = '5m';

subtest 'intraday' => sub {
    subtest 'CALL - not expired 1 second before expiry' => sub {
        my $c = produce_contract({%$args, date_pricing => $args->{date_start}->plus_time_interval($args->{duration})->minus_time_interval('1s')});
        ok !$c->is_expired, 'not expired';
    };

    subtest 'CALL - date_pricing == date_expiry with inconsistent exit tick' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch + 1, $symbol], [99, $now->epoch + 2, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $args->{date_start}->plus_time_interval($args->{duration})});
        ok $c->is_expired, 'is expired';
        is $c->entry_tick->quote, 100, 'entry tick is 100';
        is $c->exit_tick->quote,  99,  'exit tick is 99';
        ok !$c->is_valid_to_sell, 'not valid to sell';
        is $c->primary_validation_error->message, 'exit tick is inconsistent';
        ok $c->waiting_for_settlement_tick, 'waiting for settlement tick';
        ok !$c->require_manual_settlement, 'does not require manual settlement';
    };

    subtest 'CALL - date_pricing == date_expiry with consistent exit tick lower than entry spot' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100, $now->epoch + 1,                         $symbol],
            [99,  $now->epoch + 2,                         $symbol],
            [100, $now->plus_time_interval('5m1s')->epoch, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $args->{date_start}->plus_time_interval($args->{duration})});
        ok $c->is_expired, 'is expired';
        is $c->entry_tick->quote, 100, 'entry tick is 100';
        is $c->exit_tick->quote,  99,  'exit tick is 99';
        ok $c->is_valid_to_sell, 'not valid to sell';
        is $c->value, 0, 'loss';
    };

    subtest 'CALL - date_pricing == date_expiry with consistent exit tick higher than entry spot' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100, $now->epoch + 1,                         $symbol],
            [102, $now->epoch + 2,                         $symbol],
            [100, $now->plus_time_interval('5m1s')->epoch, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $args->{date_start}->plus_time_interval($args->{duration})});
        ok $c->is_expired, 'is expired';
        is $c->entry_tick->quote, 100, 'entry tick is 100';
        is $c->exit_tick->quote,  102, 'exit tick is 102';
        ok $c->is_valid_to_sell, 'not valid to sell';
        is $c->value, $c->payout, 'win';
    };
};

# this has to be a date in the past because of some quirks in getting OHLC in the future
$now                = Date::Utility->new('2019-03-04');
$args->{date_start} = $now;
$args->{duration}   = '1d';

subtest 'multiday' => sub {
    subtest 'CALL - expired but no OHLC data' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100, $now->epoch + 1,                                                 $symbol],
            [102, $now->epoch + 2,                                                 $symbol],
            [100, $now->truncate_to_day->plus_time_interval('1d23h59m59s')->epoch, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $args->{date_start}->truncate_to_day->plus_time_interval('2d')->epoch});
        ok $c->expiry_daily, 'multi-day contract';
        ok $c->is_expired,   'is expired';
        is $c->exit_tick->quote, 100, 'exit tick is 100';
        ok !$c->is_valid_to_sell, 'not valid to sell';
        is $c->primary_validation_error->message, 'exit tick is inconsistent';
        ok $c->waiting_for_settlement_tick, 'waiting for settlement tick';
        ok !$c->require_manual_settlement, 'does not require manual settlement';
    };

    subtest 'CALL - expired with OHLC data' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => $symbol,
            epoch      => $args->{date_start}->truncate_to_day->plus_time_interval('2d')->epoch,
            quote      => 100,
        });
        my $c = produce_contract({%$args, date_pricing => $args->{date_start}->truncate_to_day->plus_time_interval('2d')->epoch});
        ok $c->expiry_daily, 'multi-day contract';
        ok $c->is_expired,   'is expired';
        is $c->exit_tick->quote, 100, 'exit tick is 100';
        ok $c->is_valid_to_sell, 'valid to sell';
        ok !$c->waiting_for_settlement_tick, 'waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'loss - because close == barrier';
    };
};

done_testing();
