#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Data::Utility::FeedTestDatabase;
use Date::Utility;

my $now = Date::Utility->new('2024-01-31 01:00:23');

subtest 'shortcode' => sub {
    my $args = {
        bet_type            => 'MULTDOWN',
        underlying          => 'R_100',
        date_start          => $now,
        date_pricing        => $now,
        amount_type         => 'stake',
        amount              => 100,
        multiplier          => 10,
        currency            => 'USD',
        next_tick_execution => 1
    };
    my $c  = produce_contract($args);
    my $sc = $c->shortcode;
    is $sc, 'MULTDOWN_R_100_100.00_10_' . $now->epoch . '_' . $c->date_expiry->epoch . '_0_0.00_N1', 'shortcode populated correctly';

    my $sc_legacy = 'MULTDOWN_R_100_100.00_10_' . $now->epoch . '_' . $c->date_expiry->epoch . '_0_0.00';
    $c = produce_contract($sc_legacy, 'USD');
    is $c->next_tick_execution, undef, 'next_tick_execution is not set to anything';

    $c = produce_contract($sc, 'USD');
    is $c->next_tick_execution, 1, 'next_tick_execution is set to 1';
};

subtest 'make sure pricing is using next tick' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [99.99,  $now->epoch - 1, 'R_100'],
        [100.10, $now->epoch,     'R_100'],
        [100.07, $now->epoch + 1, 'R_100'],
        [100.09, $now->epoch + 2, 'R_100'],
        [100.10, $now->epoch + 3, 'R_100'],
        [100.12, $now->epoch + 4, 'R_100'],
        [100.11, $now->epoch + 5, 'R_100']);

    my $args = {
        bet_type            => 'MULTUP',
        underlying          => 'R_100',
        date_start          => $now,
        date_pricing        => $now,
        amount_type         => 'stake',
        amount              => 100,
        multiplier          => 10,
        currency            => 'USD',
        next_tick_execution => 1
    };
    $args->{limit_order} = {
        stop_out => {
            order_type   => 'stop_out',
            order_amount => -100,
            order_date   => $now->epoch,
            basis_spot   => '99.99',
        }};

    my $c = produce_contract($args);

    ok $c->pricing_new;
    is $c->entry_tick, undef, 'entry tick is undef at the start';

    $args->{date_pricing} = $now->epoch + 1;
    $c = produce_contract($args);

    is $c->entry_spot, 100.07, 'entry spot is 100.07 for next tick execution';
    is $c->basis_spot, 100.07, 'basis spot is same as entry spot despite defined in stop out';

    $args->{date_pricing} = $now->epoch + 2;
    $c = produce_contract($args);
    my $bid_price_next_tick_exec = $c->bid_price;    #entry spot 100.07, current spot 100.09;

    delete $args->{next_tick_execution};
    $c = produce_contract($args);
    my $bid_price_spot_exec = $c->bid_price;         #entry spot 99.9, current spot 100.09;

    ok $bid_price_spot_exec > $bid_price_next_tick_exec, 'since spot execution is not using next tick, bid price is higher';
};

subtest 'next tick execution for limit orders' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [99.99,  $now->epoch - 1, 'R_100'],
        [100.10, $now->epoch,     'R_100'],
        [100.07, $now->epoch + 1, 'R_100']);

    my $args = {
        bet_type            => 'MULTDOWN',
        underlying          => 'R_100',
        date_start          => $now,
        date_pricing        => $now->epoch + 1,
        amount_type         => 'stake',
        amount              => 100,
        multiplier          => 10,
        currency            => 'USD',
        next_tick_execution => 0
    };

    # 99.99 is the current spot at date_start
    # they will be inserted into child table
    $args->{limit_order} = {
        stop_out => {
            order_type   => 'stop_out',
            order_amount => -100,
            order_date   => $now->epoch,
            basis_spot   => '99.99',
        },
        take_profit => {
            order_type   => 'take_profit',
            order_amount => 100,
            order_date   => $now->epoch,
            basis_spot   => '99.99',
        },
        stop_loss => {
            order_type   => 'stop_loss',
            order_amount => -100,
            order_date   => $now->epoch,
            basis_spot   => '99.99',
        }};

    my $c = produce_contract($args);
    is $c->stop_out->basis_spot,    99.99, 'stop out basis spot is 99.99 for spot execution';
    is $c->take_profit->basis_spot, 99.99, 'take profit basis spot is 99.99 for spot execution';
    is $c->stop_loss->basis_spot,   99.99, 'stop loss basis spot is 99.99 for spot execution';

    $args->{next_tick_execution} = 1;
    $c = produce_contract($args);
    is $c->stop_out->basis_spot,    100.07, 'stop out basis spot is 100.07 for next tick execution';
    is $c->take_profit->basis_spot, 100.07, 'take profit basis spot is 100.07 for next tick execution';
    is $c->stop_loss->basis_spot,   100.07, 'stop loss basis spot is 100.07 for next tick execution';

};

done_testing();
