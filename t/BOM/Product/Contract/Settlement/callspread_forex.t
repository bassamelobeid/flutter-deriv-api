#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Test::Exception;
use Test::MockModule;
use Test::MockTime qw/:all/;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory                qw(produce_contract);
use Finance::Contract::Longcode                  qw(shortcode_to_parameters);
use BOM::MarketData                              qw(create_underlying);

initialize_realtime_ticks_db();

my $datetime   = Date::Utility->new('2013-03-27 08:00:34');
my $symbol     = 'frxUSDJPY';
my $underlying = create_underlying($symbol);
set_absolute_time($datetime->epoch);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $datetime
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $symbol,
        recorded_date => $datetime,
    });

my $args = {
    bet_type      => 'CALLSPREAD',
    underlying    => $symbol,
    date_start    => $datetime,
    date_pricing  => $datetime,
    barrier_range => 'wide',
    duration      => '5m',
    currency      => 'USD',
    payout        => 100,
};

subtest 'intraday' => sub {
    subtest 'CALLSPREAD - exit tick higher than high barrier = full payout' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,     $datetime->epoch,       $symbol],
            [100,     $datetime->epoch + 1,   $symbol],
            [101.332, $datetime->epoch + 300, $symbol]);

        # We need to first create the contract and fetch the shortcode
        my $c          = produce_contract($args);
        my $params_ref = shortcode_to_parameters($c->shortcode, $c->currency);
        $params_ref->{date_pricing} = $datetime->plus_time_interval('5m');

        # Create contract using shortcode
        $c = produce_contract($params_ref);
        is $c->entry_tick->quote,         100,       'entry tick is 100';
        is $c->high_barrier->as_absolute, '101.332', 'high barrier is 101.332';
        is $c->low_barrier->as_absolute,  '98.668',  'low barrier is 98.668';
        is $c->exit_tick->quote,          101.332,   'exit tick is 101.332';
        ok $c->is_expired,                   'contract is expired';
        ok $c->is_valid_to_sell,             'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, $c->payout, 'win';
    };

    subtest 'CALLSPREAD - exit tick in between high and low barrier = partial payout' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,    $datetime->epoch,       $symbol],
            [100,    $datetime->epoch + 1,   $symbol],
            [99.999, $datetime->epoch + 300, $symbol]);

        # We need to first create the contract and fetch the shortcode
        my $c          = produce_contract($args);
        my $params_ref = shortcode_to_parameters($c->shortcode, $c->currency);
        $params_ref->{date_pricing} = $datetime->plus_time_interval('5m');

        # Create contract using shortcode
        $c = produce_contract($params_ref);
        is $c->entry_tick->quote,         100,       'entry tick is 100';
        is $c->high_barrier->as_absolute, '101.332', 'high barrier is 101.332';
        is $c->low_barrier->as_absolute,  '98.668',  'low barrier is 98.668';
        is $c->exit_tick->quote,          99.999,    'exit tick is 99.999';
        ok $c->is_expired,                   'contract is expired';
        ok $c->is_valid_to_sell,             'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 49.9624624624623, 'value equal payout';
    };

    subtest 'CALLSPREAD - exit tick is lower than low barrier = zero payout' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,   $datetime->epoch,       $symbol],
            [100,   $datetime->epoch + 1,   $symbol],
            [98.65, $datetime->epoch + 300, $symbol]);

        # We need to first create the contract and fetch the shortcode
        my $c          = produce_contract($args);
        my $params_ref = shortcode_to_parameters($c->shortcode, $c->currency);
        $params_ref->{date_pricing} = $datetime->plus_time_interval('5m');

        # Create contract using shortcode
        $c = produce_contract($params_ref);
        is $c->entry_tick->quote,         100,       'entry tick is 100';
        is $c->high_barrier->as_absolute, '101.332', 'high barrier is 101.332';
        is $c->low_barrier->as_absolute,  '98.668',  'low barrier is 98.668';
        is $c->exit_tick->quote,          98.65,     'exit tick is 98.65';
        ok $c->is_expired,                   'contract is expired';
        ok $c->is_valid_to_sell,             'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'zero payout';
    };
};

subtest 'intraday' => sub {
    subtest 'CALLSPREAD - exit tick higher than high barrier = full payout' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,     $datetime->epoch,     $symbol],
            [100,     $datetime->epoch + 1, $symbol],
            [100,     $datetime->epoch + 2, $symbol],
            [100,     $datetime->epoch + 3, $symbol],
            [100,     $datetime->epoch + 4, $symbol],
            [101.321, $datetime->epoch + 5, $symbol]);

        # Change to tick duration
        $args->{duration} = '5t';

        # We need to first create the contract and fetch the shortcode
        my $c          = produce_contract($args);
        my $params_ref = shortcode_to_parameters($c->shortcode, $c->currency);
        $params_ref->{date_pricing} = $datetime->plus_time_interval('5s');

        # Create contract using shortcode
        $c = produce_contract($params_ref);
        is $c->entry_tick->quote,         100,       'entry tick is 100';
        is $c->high_barrier->as_absolute, '101.321', 'high barrier is 101.321';
        is $c->low_barrier->as_absolute,  '98.679',  'low barrier is 98.679';
        is $c->exit_tick->quote,          101.321,   'exit tick is 101.321';
        ok $c->is_expired,                   'contract is expired';
        ok $c->is_valid_to_sell,             'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, $c->payout, 'win';
    };

    subtest 'CALLSPREAD - exit tick in between high and low barrier = partial payout' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100, $datetime->epoch,     $symbol],
            [100, $datetime->epoch + 1, $symbol],
            [100, $datetime->epoch + 2, $symbol],
            [100, $datetime->epoch + 3, $symbol],
            [100, $datetime->epoch + 4, $symbol],
            [101, $datetime->epoch + 5, $symbol]);

        # Change to tick duration
        $args->{duration} = '5t';

        # We need to first create the contract and fetch the shortcode
        my $c          = produce_contract($args);
        my $params_ref = shortcode_to_parameters($c->shortcode, $c->currency);
        $params_ref->{date_pricing} = $datetime->plus_time_interval('5s');

        # Create contract using shortcode
        $c = produce_contract($params_ref);
        is $c->entry_tick->quote,         100,       'entry tick is 100';
        is $c->high_barrier->as_absolute, '101.321', 'high barrier is 101.321';
        is $c->low_barrier->as_absolute,  '98.679',  'low barrier is 98.679';
        is $c->exit_tick->quote,          101,       'exit tick is 101';
        ok $c->is_expired,                   'contract is expired';
        ok $c->is_valid_to_sell,             'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 87.8501135503407, 'value equal payout';
    };

    subtest 'CALLSPREAD - exit tick is lower than low barrier = zero payout' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100,   $datetime->epoch,     $symbol],
            [100,   $datetime->epoch + 1, $symbol],
            [100,   $datetime->epoch + 2, $symbol],
            [100,   $datetime->epoch + 3, $symbol],
            [100,   $datetime->epoch + 4, $symbol],
            [98.65, $datetime->epoch + 5, $symbol]);

        # Change to tick duration
        $args->{duration} = '5t';

        # We need to first create the contract and fetch the shortcode
        my $c          = produce_contract($args);
        my $params_ref = shortcode_to_parameters($c->shortcode, $c->currency);
        $params_ref->{date_pricing} = $datetime->plus_time_interval('5s');

        # Create contract using shortcode
        $c = produce_contract($params_ref);
        is $c->entry_tick->quote,         100,       'entry tick is 100';
        is $c->high_barrier->as_absolute, '101.321', 'high barrier is 101.321';
        is $c->low_barrier->as_absolute,  '98.679',  'low barrier is 98.679';
        is $c->exit_tick->quote,          98.65,     'exit tick is 98.65';
        ok $c->is_expired,                   'contract is expired';
        ok $c->is_valid_to_sell,             'is valid to sell';
        ok !$c->waiting_for_settlement_tick, 'not waiting for settlement tick';
        ok !$c->require_manual_settlement,   'does not require manual settlement';
        is $c->value, 0, 'zero payout';
    };
};

done_testing();
