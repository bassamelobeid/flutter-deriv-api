#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;

use Try::Tiny;

my $now = Date::Utility->new;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

subtest 'pricing new - general' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100']);
    my $args = {
        bet_type     => 'MULTDOWN',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        commission   => 0,            # setting commission to zero for easy calculation
    };
    my $c = produce_contract($args);
    is $c->code,            'MULTDOWN', 'code is MULTDOWN';
    is $c->pricing_code,    'MULTDOWN', 'pricing_code is MULTDOWN';
    is $c->other_side_code, undef,      'other_side_code is undef';
    ok !$c->pricing_engine,      'pricing_engine is undef';
    ok !$c->pricing_engine_name, 'pricing_engine_name is undef';
    is $c->multiplier, 10,  'multiplier is 10';
    is $c->ask_price,  100, 'ask_price is 100';
    ok !$c->take_profit, 'take_profit is undef';
    isa_ok $c->stop_out, 'BOM::Product::LimitOrder';
    is $c->stop_out->order_type, 'stop_out';
    is $c->stop_out->order_date->epoch, $c->date_pricing->epoch;
    is $c->stop_out->order_amount,  -100;
    is $c->stop_out->basis_spot,    '100.00';
    is $c->stop_out->barrier_value, '110.00';

    $args->{limit_order} = {
        'take_profit' => 50,
    };
    $c = produce_contract($args);
    isa_ok $c->take_profit, 'BOM::Product::LimitOrder';
    is $c->take_profit->order_type, 'take_profit';
    is $c->take_profit->order_date->epoch, $c->date_pricing->epoch;
    is $c->take_profit->order_amount,  50;
    is $c->take_profit->basis_spot,    '100.00';
    is $c->take_profit->barrier_value, '95.00';

    $args->{limit_order} = {
        'take_profit' => 0,
    };
    $c = produce_contract($args);
    try { $c->take_profit }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Take profit must be greater than zero.', 'take profit must be greater than 0';
    };
};

subtest 'non-pricing new' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100']);
    my $args = {
        bet_type     => 'MULTDOWN',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now->epoch + 1,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        commission   => 0,                 # setting commission to zero for easy calculation
    };
    my $c = produce_contract($args);
    ok !$c->pricing_new, 'non pricing_new';
    try {
        $c->stop_out
    }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Cannot validate contract.', 'contract is invalid because stop_out is undef';
    };

    $args->{limit_order} = {
        stop_out => {
            order_type   => 'stop_out',
            order_amount => -100,
            order_date   => $now->epoch,
            basis_spot   => '100.00',
        }};

    $c = produce_contract($args);
    is $c->stop_out->order_type, 'stop_out';
    is $c->stop_out->order_date->epoch, $c->date_start->epoch;
    is $c->stop_out->order_amount,  -100;
    is $c->stop_out->basis_spot,    '100.00';
    is $c->stop_out->barrier_value, '110.00';
};

subtest 'shortcode' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100']);
    my $args = {
        bet_type     => 'MULTDOWN',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        commission   => 0,            # setting commission to zero for easy calculation
    };
    my $c = produce_contract($args);
    is $c->shortcode, 'MULTDOWN_R_100_100_10_' . $now->epoch . '_' . $c->date_expiry->epoch, 'shortcode populated correctly';
};

subtest 'minmum stake' => sub {
    my $args = {
        bet_type    => 'MULTDOWN',
        underlying  => 'R_100',
        amount_type => 'stake',
        amount      => 0.9,
        multiplier  => 10,
        currency    => 'USD',
        commission  => 0,            # setting commission to zero for easy calculation
    };
    my $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'multiplier stake lower than minimum', 'message - multiplier stake lower than minimum';
    is $c->primary_validation_error->message_to_client->[0], 'Stake must be at least [_1] 1.', 'message to client - Stake must be at least [_1] 1.';
    is $c->primary_validation_error->message_to_client->[1], 'USD';
};

subtest 'take profit cap' => sub {
    my $args = {
        bet_type    => 'MULTDOWN',
        underlying  => 'R_100',
        amount_type => 'stake',
        amount      => 10,
        multiplier  => 10,
        currency    => 'USD',
        commission  => 0,          # setting commission to zero for easy calculation
        limit_order => {
            take_profit => 10000 + 0.01,
        },
    };
    my $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'take profit too high', 'message - take profit too high';
    is $c->primary_validation_error->message_to_client, 'Invalid take profit. Take profit cannot be more than 100 times of stake.';
};

done_testing();
