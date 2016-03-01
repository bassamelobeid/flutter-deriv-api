#!/usr/bin/perl

use strict;
use warnings;

use Test::MockModule;
use BOM::Product::ContractFactory qw(produce_contract);
use Test::More tests => 3;
use Test::NoWarnings;
use Math::Util::CalculatedValue::Validatable;

subtest 'payout' => sub {
    my $mocked           = Test::MockModule->new('BOM::Product::Contract::Call');
    my $payout           = 10;
    my $min_total_markup = 0.02 / $payout;
    $mocked->mock(
        'model_markup',
        Math::Util::CalculatedValue::Validatable->new({
                name        => 'model_markup',
                description => 'test model markup',
                set_by      => 'test',
                base_amount => $min_total_markup - 0.001,
            }));
    my $c = produce_contract({
        bet_type   => 'CALL',
        underlying => 'R_100',
        barrier    => 'S0P',
        duration   => '10m',
        currency   => 'USD',
        payout     => $payout,
    });
    is $c->total_markup->amount, $min_total_markup, 'total_markup amount is floored 0.002 when payout is 10';
};

subtest 'stake' => sub {
    my $mocked          = Test::MockModule->new('BOM::Product::Contract::Call');
    my $stake           = 10;
    my $ask_probability = 0.1;
    my $payout          = $stake / $ask_probability;
    $mocked->mock(
        'ask_probability',
        Math::Util::CalculatedValue::Validatable->new({
                name        => 'ask_probability',
                description => 'test ask probability',
                set_by      => 'test',
                base_amount => $ask_probability,
            }));
    my $min_total_markup = 0.02 / $payout;
    $mocked->mock(
        'total_markup',
        Math::Util::CalculatedValue::Validatable->new({
                name        => 'total_markup',
                description => 'test total markup',
                set_by      => 'test',
                base_amount => $min_total_markup - 0.0001,
            }));
    my $c = produce_contract({
        bet_type    => 'CALL',
        underlying  => 'R_100',
        barrier     => 'S0P',
        duration    => '10m',
        currency    => 'USD',
        amount_type => 'stake',
        amount      => $stake,
    });
    is $c->payout, 99.99, 'payout is re-adjusted to 99.99 to get a minimum commission of 2 cents';
};
