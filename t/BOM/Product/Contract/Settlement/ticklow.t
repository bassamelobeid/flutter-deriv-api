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
    bet_type      => 'TICKLOW',
    underlying    => $symbol,
    date_start    => $now,
    duration      => '5t',
    selected_tick => 1,
    currency      => 'USD',
    payout        => 100,
};

subtest 'tick expiry' => sub {
    subtest 'TICKLOW - selected tick is 1 and second tick is lwer than first. Contract will be settled as a loss' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch + 1, $symbol], [99.99, $now->epoch + 2, $symbol]);
        my $c = eval { produce_contract({%$args, date_pricing => $now->plus_time_interval('2s')}) };
        is $c->entry_tick->quote, 100,   'entry tick is 100';
        is $c->hit_tick->quote,   99.99, 'hit tick is 99.99';
        ok !$c->lowest_tick, 'lowest tick is undefined';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'loss';
    };

    $args->{selected_tick} = 2;
    subtest 'TICKLOW - selected tick is 2 and first tick is lower than second. Contract will be settled as a loss' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([99.99, $now->epoch + 1, $symbol], [100, $now->epoch + 2, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('2s')});
        is $c->entry_tick->quote, 99.99, 'entry tick is 99.99';
        is $c->hit_tick->quote,   99.99, 'hit tick is 99.99';
        ok !$c->lowest_tick, 'lowest tick is undefined';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'loss';
    };

    subtest 'TICKLOW - selected tick is 2 and first tick is equal to second. Contract will be settled as a win' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100.1, $now->epoch + 1, $symbol],
            [100.1, $now->epoch + 2, $symbol],
            [101.1, $now->epoch + 3, $symbol],
            [101.1, $now->epoch + 4, $symbol],
            [102.1, $now->epoch + 5, $symbol],
        );
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('2s')});
        is $c->entry_tick->quote, 100.1, 'entry tick is 100.1';
        ok !$c->hit_tick, 'hit tick is undefined';
        is $c->lowest_tick->quote, 100.1, 'lowest tick is 100.1';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, $c->payout, 'win';
    };

    subtest 'TICKLOW - selected tick is 2 and second tick is the lowest tick. Contract will be settled as a win' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100.01, $now->epoch + 1, $symbol],
            [99.09,  $now->epoch + 2, $symbol],
            [99.1,   $now->epoch + 3, $symbol],
            [99.1,   $now->epoch + 4, $symbol],
            [99.1,   $now->epoch + 5, $symbol],
        );
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('2s')});
        is $c->entry_tick->quote, 100.01, 'entry tick is 100.01';
        ok !$c->hit_tick, 'hit tick is undefined';
        is $c->lowest_tick->quote, 99.09, 'lowest tick is 99.09';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, $c->payout, 'win';
    };

    subtest 'TICKLOW - selected tick is 2 and third tick is lower than second tick. Contract will be settled as a loss' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100.1,  $now->epoch + 1, $symbol],
            [100.1,  $now->epoch + 2, $symbol],
            [100.09, $now->epoch + 3, $symbol],
            [100.21, $now->epoch + 4, $symbol],
            [100.08, $now->epoch + 5, $symbol],
        );
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('2s')});
        is $c->entry_tick->quote,  100.1,  'entry tick is 100.1';
        is $c->hit_tick->quote,    100.09, 'hit tick is 100.09';
        is $c->lowest_tick->quote, 100.08, 'lowest tick is 100.08';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'loss';
    };
};

done_testing();
