#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::FailWarnings;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;

my $now = Date::Utility->new;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

subtest 'past date_expiry' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [101, $now->epoch + 100 * 365 * 86400, 'R_100']);
    my $args = {
        bet_type     => 'MULTDOWN',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now->plus_time_interval(100 * 365 . 'd1s'),
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        commission   => 0,                                             # setting commission to zero for easy calculation
        limit_order  => {
            stop_out => {
                order_type   => 'stop_out',
                order_amount => -100,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            }}};
    my $c = produce_contract($args);
    ok !$c->hit_tick, 'no hit tick';
    ok $c->is_expired, 'expired because it has past date_expiry';
    is $c->value + 0, $c->bid_price + 0, 'contract is closed at bid price';
};

subtest 'hit stop out' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [109.99, $now->epoch + 1, 'R_100']);
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
        limit_order  => {
            stop_out => {
                order_type   => 'stop_out',
                order_amount => -100,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            }}};
    my $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';
    ok !$c->hit_tick,   'no hit tick';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [110, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->value,      '0.00', 'value of contract is zero';
    is $c->current_pnl(), '-100.00', 'pnl at -100';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [111, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->value,      '0.00', 'value of contract is zero and does not go negative';
    is $c->current_pnl(), '-110.00', 'pnl at -110';

    note('stop out with 0.01 commission');
    $args->{commission} = 0.01;
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [108.99, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [109, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->hit_tick->quote, 109, 'hit tick is 109';
    is $c->value, '0.00', 'value of contract is zero';
    is $c->current_pnl(), '-100.00', 'pnl at -100';
};

subtest 'hit take profit' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [99.01, $now->epoch + 1, 'R_100']);
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
        limit_order  => {
            stop_out => {
                order_type   => 'stop_out',
                order_amount => -100,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            },
            take_profit => {
                order_type   => 'take_profit',
                order_amount => 10,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            }
        },
    };
    my $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';
    ok !$c->hit_tick,   'no hit tick';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [99, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->value,      '110.00', 'value of contract is 110';
    is $c->current_pnl(), '10.00', 'pnl at 10';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [98.99, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->value,      '110.10', 'value of contract is 110.1';
    is $c->current_pnl(), '10.10', 'pnl at 10.1';

    note('take profit with 0.01 commission');
    $args->{commission} = 0.01;
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [98.01, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [98, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->hit_tick->quote, 98, 'hit tick is 98';
    is $c->value, '110.00', 'value of contract is zero and does not go negative';
    is $c->current_pnl(), '10.00', 'pnl at 10';
};

subtest 'hit stop loss' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [109.49, $now->epoch + 1, 'R_100']);
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
        limit_order  => {
            stop_out => {
                order_type   => 'stop_out',
                order_amount => -100,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            },
            stop_loss => {
                order_type => 'stop_loss',
                    order_amount => -95,
                        order_date => $now->epoch,
                        basis_spot => '100.00',
            }
        }};
    my $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';
    ok !$c->hit_tick,   'no hit tick';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [109.50, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->hit_tick->quote, 109.5, 'hit tick is 109.5';
    is $c->value,      '5.00', 'value of contract is 5.00';
    is $c->current_pnl(), '-95.00', 'pnl at -95';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [109.51, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->hit_tick->quote, 109.51, 'hit tick is 109.51';
    is $c->value,      '4.90', 'value of contract is 4.90';
    is $c->current_pnl(), '-95.10', 'pnl at -95.10';
};

subtest 'sell late' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100, $now->epoch,     'R_100'],
        [99,  $now->epoch + 1, 'R_100'],
        [110, $now->epoch + 2, 'R_100']);
    my $args = {
        bet_type     => 'MULTDOWN',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now->epoch + 2,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        commission   => 0,                 # setting commission to zero for easy calculation
        sell_time    => $now->epoch + 2,
        limit_order  => {
            stop_out => {
                order_type   => 'stop_out',
                order_amount => -100,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            },
            take_profit => {
                order_type   => 'take_profit',
                order_amount => 10,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            }}};
    my $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->hit_tick->quote, 99, 'hit tick is 99';
    is $c->value, '110.00', 'value is 110';
    is $c->current_pnl(), '10.00', 'pnl at 10';
};

subtest 'is valid to buy/sell' => sub {
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
    };
    my $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';
};

subtest 'bid price after expiry' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [99, $now->epoch + 1, 'R_100'], [99.02, $now->epoch + 2, 'R_100']);
    my $args = {
        bet_type     => 'MULTDOWN',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now->epoch + 2,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        commission   => 0,                 # setting commission to zero for easy calculation
        limit_order  => {
            stop_out => {
                order_type   => 'stop_out',
                order_amount => -100,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            },
            take_profit => {
                order_type   => 'take_profit',
                order_amount => 10,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            }
        },
    };
    my $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'hit tick';
    is $c->value,      '110.00', 'value of contract is 110';
    ok $c->bid_price == $c->value, 'bid price == value after expiry';
};

done_testing();
