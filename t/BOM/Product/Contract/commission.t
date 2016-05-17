#!/usr/bin/perl

use strict;
use warnings;

use Format::Util::Numbers qw(roundnear);
use Test::MockModule;
use BOM::Product::ContractFactory qw(produce_contract);
use Test::More tests => 4;
use Test::NoWarnings;
use Math::Util::CalculatedValue::Validatable;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use Date::Utility;

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

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
    my $mocked            = Test::MockModule->new('BOM::Product::Contract::Call');
    my $stake             = 0.5;
    $mocked->mock('base_commission', sub { 0 });
    $mocked->mock('theo_probability', sub {
        Math::Util::CalculatedValue::Validatable->new({
                name        => 'theo_probability',
                description => 'test theo',
                set_by      => 'test',
                base_amount => 0.5,
            })});
    my $c = produce_contract({
        bet_type    => 'CALL',
        underlying  => 'R_100',
        barrier     => 'S0P',
        duration    => '10m',
        currency    => 'USD',
        amount_type => 'stake',
        amount      => $stake,
    });
    is $c->payout, 0.96, 'payout is re-adjusted to 0.96 to get a minimum commission of 2 cents';
};

subtest 'new commission structure' => sub {
    my $fake_risk = Math::Util::CalculatedValue::Validatable->new({
        name        => 'risk_markup',
        description => 'test total markup',
        set_by      => 'test',
        base_amount => 0.01,
    });
    my $base_commission = 0.02;
    my %test_cases = (
        0.5 => [
            {
                stake => 520,
                payout => 981.132,
            },
            {
                stake => 540,
                payout => 1018.853,
            },
            {
                stake => 27000,
                payout => 49122.88,
            },
            {
                stake => 28000,
                payout => 50909.09,
            },
        ],
        0.75 => [
            {
                stake => 900,
                payout => 1153.846,
            },
            {
                stake => 1000,
                payout => 1281.977,
            },
            {
                stake => 46000,
                payout => 57505.82,
            },
            {
                stake => 47000,
                payout => 58750,
            },
        ],
    );

    foreach my $theo (keys %test_cases) {
        my $fake_theo = Math::Util::CalculatedValue::Validatable->new({
            name        => 'theo_probability',
            description => 'test theo',
            set_by      => 'test',
            base_amount => $theo,
        });
        foreach my $data (@{$test_cases{$theo}}) {
            my $stake = $data->{stake};
            my $c = produce_contract({
                bet_type    => 'CALL',
                underlying  => 'R_100',
                barrier     => 'S0P',
                duration    => '10m',
                currency    => 'USD',
                amount_type => 'stake',
                amount      => $stake,
                base_commission => $base_commission,
                risk_markup => $fake_risk,
                theo_probability => $fake_theo,
            });
            is $c->payout, roundnear(0.01,$data->{payout}), 'correct payout amount';
        }
    }
};
