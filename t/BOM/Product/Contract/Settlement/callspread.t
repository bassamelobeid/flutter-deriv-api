#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Test::Exception;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory                qw(produce_contract);
use Finance::Contract::Longcode                  qw(shortcode_to_parameters);

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
    bet_type      => 'CALLSPREAD',
    underlying    => $symbol,
    date_start    => $now,
    date_pricing  => $now,
    barrier_range => 'middle',
    duration      => '5m',
    currency      => 'USD',
    payout        => 100
};

subtest 'intraday' => sub {
    subtest 'CALLSPREAD - exit tick higher than high barrier = full payout' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,    $now->epoch,       $symbol],
            [100,    $now->epoch + 1,   $symbol],
            [100.65, $now->epoch + 300, $symbol]);

        # We need to first create the contract and fetch the shortcode
        my $c          = produce_contract($args);
        my $params_ref = shortcode_to_parameters($c->shortcode, $c->currency);
        $params_ref->{date_pricing} = $now->plus_time_interval('5m');

        # Create contract using shortcode
        $c = produce_contract($params_ref);
        is $c->high_barrier->as_absolute, '100.52', 'high barrier is 100.52';
        is $c->low_barrier->as_absolute,  '99.48',  'low barrier is 99.48';
        is $c->entry_tick->quote,         100,      'entry tick is 100';
        is $c->exit_tick->quote,          100.65,   'exit tick is 100.65';
        ok $c->is_expired,                   'contract is expired';
        ok $c->is_valid_to_sell,             'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, $c->payout, 'win';
    };

    subtest 'CALLSPREAD - exit tick in between high and low barrier = partial payout' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,    $now->epoch,       $symbol],
            [100,    $now->epoch + 1,   $symbol],
            [100.09, $now->epoch + 300, $symbol]);

        # We need to first create the contract and fetch the shortcode
        my $c          = produce_contract($args);
        my $params_ref = shortcode_to_parameters($c->shortcode, $c->currency);
        $params_ref->{date_pricing} = $now->plus_time_interval('5m');

        # Create contract using shortcode
        $c = produce_contract($params_ref);
        is $c->entry_tick->quote,         100,      'entry tick is 100';
        is $c->high_barrier->as_absolute, '100.52', 'high barrier is 100.52';
        is $c->low_barrier->as_absolute,  '99.48',  'low barrier is 99.48';
        is $c->exit_tick->quote,          '100.09', 'exit tick is 100.09';
        ok $c->is_expired,                   'contract is expired';
        ok $c->is_valid_to_sell,             'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 58.6538461538465, 'value less than payout';
    };

    subtest 'CALLSPREAD - exit tick is lower than low barrier = zero payout' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,   $now->epoch,       $symbol],
            [100,   $now->epoch + 1,   $symbol],
            [99.41, $now->epoch + 300, $symbol]);

        # We need to first create the contract and fetch the shortcode
        my $c          = produce_contract($args);
        my $params_ref = shortcode_to_parameters($c->shortcode, $c->currency);
        $params_ref->{date_pricing} = $now->plus_time_interval('5m');

        # Create contract using shortcode
        $c = produce_contract($params_ref);
        is $c->entry_tick->quote,         100,      'entry tick is 100';
        is $c->high_barrier->as_absolute, '100.52', 'high barrier is 100.52';
        is $c->low_barrier->as_absolute,  '99.48',  'low barrier is 99.48';
        is $c->exit_tick->quote,          '99.41',  'exit tick is 99.41';
        ok $c->is_expired,                   'contract is expired';
        ok $c->is_valid_to_sell,             'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'zero payout';
    };
};

subtest 'tick contract' => sub {
    subtest 'CALLSPREAD - exit tick higher than high barrier = full payout' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,    $now->epoch,     $symbol],
            [100,    $now->epoch + 1, $symbol],
            [100,    $now->epoch + 2, $symbol],
            [100,    $now->epoch + 3, $symbol],
            [100,    $now->epoch + 4, $symbol],
            [100.65, $now->epoch + 5, $symbol]);

        # Change to tick duration
        $args->{duration} = '5t';

        # We need to first create the contract and fetch the shortcode
        my $c          = produce_contract($args);
        my $params_ref = shortcode_to_parameters($c->shortcode, $c->currency);
        $params_ref->{date_pricing} = $now->plus_time_interval('5s');

        # # Create contract using shortcode
        $c = produce_contract($params_ref);
        ok $c->is_expired, 'is expired';
        is $c->high_barrier->as_absolute, '100.52', 'high barrier is 100.52';
        is $c->low_barrier->as_absolute,  '99.48',  'low barrier is 99.48';
        is $c->entry_tick->quote,         100,      'entry tick is 100';
        is $c->exit_tick->quote,          100.65,   'exit tick is 100.65';
        ok $c->is_expired,                   'contract is expired';
        ok $c->is_valid_to_sell,             'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, $c->payout, 'win';
    };

    subtest 'CALLSPREAD - exit tick in between high and low barrier = partial payout' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,    $now->epoch,     $symbol],
            [100,    $now->epoch + 1, $symbol],
            [100,    $now->epoch + 2, $symbol],
            [100,    $now->epoch + 3, $symbol],
            [100,    $now->epoch + 4, $symbol],
            [100.09, $now->epoch + 5, $symbol]);

        # Change to tick duration
        $args->{duration} = '5t';

        # We need to first create the contract and fetch the shortcode
        my $c          = produce_contract($args);
        my $params_ref = shortcode_to_parameters($c->shortcode, $c->currency);
        $params_ref->{date_pricing} = $now->plus_time_interval('5s');

        # Create contract using shortcode
        $c = produce_contract($params_ref);
        is $c->entry_tick->quote,         100,      'entry tick is 100';
        is $c->high_barrier->as_absolute, '100.52', 'high barrier is 100.52';
        is $c->low_barrier->as_absolute,  '99.48',  'low barrier is 99.48';
        is $c->exit_tick->quote,          '100.09', 'exit tick is 100.09';
        ok $c->is_expired,                   'contract is expired';
        ok $c->is_valid_to_sell,             'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 58.6538461538465, 'value less than payout';
    };

    subtest 'CALLSPREAD - exit tick is lower than low barrier = zero payout' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,   $now->epoch,     $symbol],
            [100,   $now->epoch + 1, $symbol],
            [100,   $now->epoch + 2, $symbol],
            [100,   $now->epoch + 3, $symbol],
            [100,   $now->epoch + 4, $symbol],
            [99.41, $now->epoch + 5, $symbol]);

        # Change to tick duration
        $args->{duration} = '5t';

        # We need to first create the contract and fetch the shortcode
        my $c          = produce_contract($args);
        my $params_ref = shortcode_to_parameters($c->shortcode, $c->currency);
        $params_ref->{date_pricing} = $now->plus_time_interval('5s');

        # Create contract using shortcode
        $c = produce_contract($params_ref);
        is $c->entry_tick->quote,         100,      'entry tick is 100';
        is $c->high_barrier->as_absolute, '100.52', 'high barrier is 100.52';
        is $c->low_barrier->as_absolute,  '99.48',  'low barrier is 99.48';
        is $c->exit_tick->quote,          '99.41',  'exit tick is 99.41';
        ok $c->is_expired,                   'contract is expired';
        ok $c->is_valid_to_sell,             'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'zero payout';
    };
};

done_testing();
