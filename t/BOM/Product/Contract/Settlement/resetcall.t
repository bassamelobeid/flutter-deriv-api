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
    bet_type   => 'RESETCALL',
    underlying => $symbol,
    date_start => $now,
    barrier    => 'S0P',
    duration   => '5t',
    currency   => 'USD',
    payout     => 100,
};

subtest 'tick expiry' => sub {
    subtest 'RESETCALL - no reset and exit tick lower than barrier. Contract is settled as a loss' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,   $now->epoch + 1, $symbol],
            [101,   $now->epoch + 2, $symbol],
            [101,   $now->epoch + 3, $symbol],
            [102,   $now->epoch + 4, $symbol],
            [104,   $now->epoch + 5, $symbol],
            [99.98, $now->epoch + 6, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('12s')});
        is $c->entry_tick->quote,    100,      'entry tick is 100';
        is $c->barrier->as_absolute, '100.00', 'barrier is 100.00';
        is $c->exit_tick->quote,     99.98,    'exit tick is 99.98';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'loss';
    };

    subtest 'RESETCALL - reset at tick 2 and exit tick lower than barrier. Contract is settled as a loss' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,   $now->epoch + 1, $symbol],
            [99.99, $now->epoch + 2, $symbol],
            [99.89, $now->epoch + 3, $symbol],
            [102,   $now->epoch + 4, $symbol],
            [104,   $now->epoch + 5, $symbol],
            [98.98, $now->epoch + 6, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('12s')});
        is $c->entry_tick->quote,    100,     'entry tick is 100';
        is $c->barrier->as_absolute, '99.89', 'barrier is 99.89';
        is $c->exit_tick->quote,     98.98,   'exit tick is 98.98';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'loss';
    };

    subtest 'RESETCALL - reset at tick 2 and exit tick equals to barrier. Contract is settled as a loss' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,   $now->epoch + 1, $symbol],
            [99.99, $now->epoch + 2, $symbol],
            [99.89, $now->epoch + 3, $symbol],
            [102,   $now->epoch + 4, $symbol],
            [104,   $now->epoch + 5, $symbol],
            [99.89, $now->epoch + 6, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('12s')});
        is $c->entry_tick->quote,    100,     'entry tick is 100';
        is $c->barrier->as_absolute, '99.89', 'barrier is 99.89';
        is $c->exit_tick->quote,     99.89,   'exit tick is 99.89';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'loss';
    };

    subtest 'RESETCALL - reset at tick 2 and exit tick higher than barrier. Contract is settled as a win' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,   $now->epoch + 1, $symbol],
            [99.99, $now->epoch + 2, $symbol],
            [99.89, $now->epoch + 3, $symbol],
            [102,   $now->epoch + 4, $symbol],
            [104,   $now->epoch + 5, $symbol],
            [99.90, $now->epoch + 6, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('12s')});
        is $c->entry_tick->quote,    100,     'entry tick is 100';
        is $c->barrier->as_absolute, '99.89', 'barrier is 99.89';
        is $c->exit_tick->quote,     99.9,    'exit tick is 99.9';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, $c->payout, 'win';
    };
};

$args->{duration} = '5m';

subtest 'intraday' => sub {
    subtest 'RESETCALL - not expired 1 second before expiry' => sub {
        my $c = produce_contract({%$args, date_pricing => $args->{date_start}->plus_time_interval($args->{duration})->minus_time_interval('1s')});
        ok !$c->is_expired, 'not expired';
    };

    subtest 'RESETCALL - date_pricing == date_expiry with inconsistent exit tick' => sub {
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

    subtest 'RESETCALL - resets at 2m30s after contract start and exit tick is lower than barrier. Contract is settled as a loss' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,   $now->epoch + 1,                         $symbol],
            [99,    $now->epoch + 149,                       $symbol],
            [98.99, $now->plus_time_interval('5m')->epoch,   $symbol],
            [100,   $now->plus_time_interval('5m1s')->epoch, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $args->{date_start}->plus_time_interval($args->{duration})});
        ok $c->is_expired, 'is expired';
        is $c->entry_tick->quote,    100,     'entry tick is 100';
        is $c->barrier->as_absolute, '99.00', 'barrier is 99.00';
        is $c->exit_tick->quote,     98.99,   'exit tick is 98.99';
        ok $c->is_valid_to_sell, 'not valid to sell';
        is $c->value, 0, 'loss';
    };

    subtest 'RESETCALL - resets at 2m30s after contract start and exit tick is equals to barrier. Contract is settled as a loss' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100, $now->epoch + 1,                         $symbol],
            [99,  $now->epoch + 149,                       $symbol],
            [99,  $now->plus_time_interval('5m')->epoch,   $symbol],
            [100, $now->plus_time_interval('5m1s')->epoch, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $args->{date_start}->plus_time_interval($args->{duration})});
        ok $c->is_expired, 'is expired';
        is $c->entry_tick->quote,    100,     'entry tick is 100';
        is $c->barrier->as_absolute, '99.00', 'barrier is 99.00';
        is $c->exit_tick->quote,     99,      'exit tick is 99';
        ok $c->is_valid_to_sell, 'not valid to sell';
        is $c->value, 0, 'loss';
    };

    subtest 'RESETCALL - resets at 2m30s after contract start and exit tick is higher than barrier. Contract is settled as a win' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,   $now->epoch + 1,                         $symbol],
            [99,    $now->epoch + 149,                       $symbol],
            [99.01, $now->plus_time_interval('5m')->epoch,   $symbol],
            [100,   $now->plus_time_interval('5m1s')->epoch, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $args->{date_start}->plus_time_interval($args->{duration})});
        ok $c->is_expired, 'is expired';
        is $c->entry_tick->quote,    100,     'entry tick is 100';
        is $c->barrier->as_absolute, '99.00', 'barrier is 99.00';
        is $c->exit_tick->quote,     99.01,   'exit tick is 99.01';
        ok $c->is_valid_to_sell, 'not valid to sell';
        is $c->value, $c->payout, 'win';
    };
};

done_testing();
