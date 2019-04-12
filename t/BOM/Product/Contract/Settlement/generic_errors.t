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

###
# This file contains the generic settlement errors for all contract types
###

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
    subtest 'require manual settlement - entry tick comes 5 minutes after contract start' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch - 1, $symbol], [101, $now->epoch + 301, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('5m1s')});
        ok $c->entry_tick, 'entry tick is defined';
        is $c->entry_tick->epoch, $now->epoch + 301, 'entry tick epoch is correct';
        ok !$c->exit_tick, 'exit tick is undefined';
        ok $c->is_expired, 'contract is expired';
        ok !$c->is_valid_to_sell, 'no valid to sell';
        like $c->primary_validation_error->message, qr/Entry tick came after the maximum delay/, 'entry tick comes after 5 minutes';
        like $c->primary_validation_error->message_to_client->[0], qr/There was a market data disruption during the contract period/,
            'refund message';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok $c->require_manual_settlement, 'require manual settlement';
    };

    subtest 'require manual settlement - exit tick comes 5 minutes after contract start' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch + 1, $symbol], [101, $now->epoch + 301, $symbol]);
        my $c = produce_contract({%$args, date_pricing => $now->plus_time_interval('5m1s')});
        ok $c->entry_tick, 'entry tick is defined';
        ok $c->exit_tick,  'exit tick is defined';
        is $c->exit_tick->epoch, $now->epoch + 301, 'exit tick epoch is correct';
        ok $c->is_expired, 'contract is expired';
        ok !$c->is_valid_to_sell, 'no valid to sell';
        like $c->primary_validation_error->message, qr/Contract has started. Exit tick came after the maximum delay/,
            'exit tick comes after 5 minutes';
        like $c->primary_validation_error->message_to_client->[0], qr/There was a market data disruption during the contract period/,
            'refund message';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok $c->require_manual_settlement, 'require manual settlement';
    };
};

subtest 'intraday' => sub {
    subtest 'require manual settlement - entry tick is after exit tick' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch - 1, $symbol], [101, $now->epoch + 301, $symbol]);
        my $c = produce_contract({
                %$args,
                duration     => '5m',
                date_pricing => $now->plus_time_interval('5m1s')});
        ok $c->entry_tick, 'entry tick is defined';
        is $c->entry_tick->epoch, $now->epoch + 301, 'entry tick epoch is correct';
        ok $c->exit_tick, 'exit tick is defined';
        is $c->exit_tick->epoch, $now->epoch - 1, 'exit tick epoch is correct';
        ok $c->is_expired, 'contract is expired';
        ok !$c->is_valid_to_sell, 'no valid to sell';
        like $c->primary_validation_error->message, qr/entry tick is after exit tick/, 'entry tick is after exit tick';
        like $c->primary_validation_error->message_to_client->[0], qr/There was a market data disruption during the contract period/,
            'refund message';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok $c->require_manual_settlement, 'require manual settlement';
    };

    subtest 'require manual settlement - entry tick undefined' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks();
        my $c = produce_contract({
                %$args,
                duration     => '5m',
                date_pricing => $now->plus_time_interval('5m1s')});
        ok !$c->entry_tick, 'entry tick is undefined';
        ok !$c->exit_tick,  'exit tick is undefined';
        ok $c->is_expired, 'contract is expired';
        ok !$c->is_valid_to_sell, 'no valid to sell';
        like $c->primary_validation_error->message, qr/entry tick is undefined/, 'entry tick is undefined';
        like $c->primary_validation_error->message_to_client->[0], qr/There was a market data disruption during the contract period/,
            'refund message';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok $c->require_manual_settlement, 'require manual settlement';
    };

    subtest 'require manual settlement - only one tick throughout contract period' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch + 1, $symbol], [100, $now->epoch + 301, $symbol]);
        my $c = produce_contract({
                %$args,
                duration     => '5m',
                date_pricing => $now->plus_time_interval('5m1s')});
        ok $c->entry_tick, 'entry tick is defined';
        ok $c->exit_tick,  'exit tick is defined';
        ok $c->entry_tick->epoch == $c->exit_tick->epoch, 'entry and exit are the same tick';
        ok $c->is_expired, 'contract is expired';
        ok !$c->is_valid_to_sell, 'no valid to sell';
        like $c->primary_validation_error->message, qr/only one tick throughout contract period/, 'only one tick throughout contract period';
        like $c->primary_validation_error->message_to_client->[0], qr/There was a market data disruption during the contract period/,
            'refund message';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok $c->require_manual_settlement, 'require manual settlement';
    };

    subtest 'require manual settlement - forward starting entry tick too old' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch - 301, $symbol], [100, $now->epoch + 1, $symbol]);
        my $c = produce_contract({
            %$args,
            duration                   => '5m',
            starts_as_forward_starting => 1,
            date_pricing               => $now->epoch + 1
        });
        ok $c->entry_tick, 'entry tick is defined';
        ok !$c->exit_tick, 'exit tick is undefined';
        ok $c->entry_tick->epoch == $now->epoch - 301, 'entry tick is older than the maximum allowed feed delay';
        ok $c->is_expired, 'contract is expired';
        ok !$c->is_valid_to_sell, 'no valid to sell';
        like $c->primary_validation_error->message, qr/entry tick is too old/, 'entry tick is too old';
        like $c->primary_validation_error->message_to_client->[0], qr/There was a market data disruption during the contract period/,
            'refund message';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok $c->require_manual_settlement, 'require manual settlement';
    };

    subtest 'require manual settlement - entry tick is undefined after expiry' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks();
        my $c = produce_contract({
            %$args,
            duration     => '5m',
            date_pricing => $now->epoch + 301
        });
        ok !$c->entry_tick, 'entry tick is defined';
        ok !$c->exit_tick,  'exit tick is undefined';
        ok $c->is_expired, 'contract is expired';
        ok !$c->is_valid_to_sell, 'no valid to sell';
        like $c->primary_validation_error->message, qr/entry tick is undefined/, 'entry tick is undefined';
        like $c->primary_validation_error->message_to_client->[0], qr/There was a market data disruption during the contract period/,
            'refund message';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok $c->require_manual_settlement, 'require manual settlement';
    };
};

done_testing();
