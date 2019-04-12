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
    bet_type   => 'RUNLOW',
    underlying => $symbol,
    date_start => $now,
    barrier    => 'S0P',
    duration   => '5t',
    currency   => 'USD',
    payout     => 100,
};

subtest 'tick expiry' => sub {
    subtest 'RUNLOW - first tick is higher than entry tick. Contract will be settled as a loss' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch + 1, $symbol], [100.01, $now->epoch + 2, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('2s')});
        is $c->entry_tick->quote, 100, 'entry tick is 100';
        is $c->hit_tick->quote,   100.01,  'hit tick is 100.01';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'loss';
    };

    subtest 'RUNLOW - first tick is equals to entry tick. Contract will be settled as a loss' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch + 1, $symbol], [100, $now->epoch + 2, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('2s')});
        is $c->entry_tick->quote, 100, 'entry tick is 100';
        is $c->hit_tick->quote,   100, 'hit tick is 100';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'loss';
    };

    subtest 'RUNLOW - second tick is higher than first tick. Contract will be settled as a loss' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,    $now->epoch + 1, $symbol],
            [99.99, $now->epoch + 2, $symbol],
            [100,    $now->epoch + 3, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('4s')});
        is $c->entry_tick->quote, 100, 'entry tick is 100';
        is $c->hit_tick->quote,   100, 'hit tick is 100';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'loss';
    };

    subtest 'RUNLOW - last tick is lower than second last tick. Contract will be settled as a loss' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,    $now->epoch + 1, $symbol],
            [99.99, $now->epoch + 2, $symbol],
            [99.98, $now->epoch + 3, $symbol],
            [99.97, $now->epoch + 4, $symbol],
            [99.96, $now->epoch + 5, $symbol],
            [99.98, $now->epoch + 6, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('10s')});
        is $c->entry_tick->quote, 100,    'entry tick is 100';
        is $c->hit_tick->quote,   99.98, 'hit tick is 99.98';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'loss';
    };

    subtest 'RUNLOW - all ticks are higher than previous tick. Contract will be settled as a win' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,    $now->epoch + 1, $symbol],
            [99.99, $now->epoch + 2, $symbol],
            [99.98, $now->epoch + 3, $symbol],
            [99.97, $now->epoch + 4, $symbol],
            [99.96, $now->epoch + 5, $symbol],
            [99.95, $now->epoch + 6, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('10s')});
        is $c->entry_tick->quote, 100, 'entry tick is 100';
        ok !$c->hit_tick, 'hit tick is undefined';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, $c->payout, 'win';
    };
};

done_testing();
