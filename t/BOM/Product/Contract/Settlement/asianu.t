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
    bet_type   => 'ASIANU',
    underlying => $symbol,
    date_start => $now,
    duration   => '6t',
    currency   => 'USD',
    payout     => 100,
};

subtest 'tick expiry' => sub {
    subtest 'ASIANU - exit tick higher than average of ticks will be settled as win' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100, $now->epoch + 1, $symbol],
            [101, $now->epoch + 2, $symbol],
            [100, $now->epoch + 3, $symbol],
            [101, $now->epoch + 4, $symbol],
            [100, $now->epoch + 5, $symbol],
            [101, $now->epoch + 6, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('12s')});
        is $c->barrier->as_absolute, '100.500', 'barrier is 100.5';
        is $c->exit_tick->quote,     101,       'exit tick is 101';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, $c->payout, 'win';
    };

    subtest 'ASIANU - exit tick equal to average of ticks will be settled as loss' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,   $now->epoch + 1, $symbol],
            [101.5, $now->epoch + 2, $symbol],
            [100,   $now->epoch + 3, $symbol],
            [101,   $now->epoch + 4, $symbol],
            [100,   $now->epoch + 5, $symbol],
            [100.5, $now->epoch + 6, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('12s')});
        is $c->barrier->as_absolute, '100.500', 'barrier is 100.5';
        is $c->exit_tick->quote,     100.5,     'exit tick is 100.5';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'loss';
    };

    subtest 'ASIANU - exit tick lower to average of ticks will be settled as loss' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,     $now->epoch + 1, $symbol],
            [101.506, $now->epoch + 2, $symbol],
            [100,     $now->epoch + 3, $symbol],
            [101,     $now->epoch + 4, $symbol],
            [100,     $now->epoch + 5, $symbol],
            [100.5,   $now->epoch + 6, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('12s')});
        is $c->barrier->as_absolute, '100.501', 'barrier is 100.501';
        is $c->exit_tick->quote,     100.5,     'exit tick is 100.5';
        ok $c->is_expired,       'contract is expired';
        ok $c->is_valid_to_sell, 'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'loss';
    };
};

done_testing();
