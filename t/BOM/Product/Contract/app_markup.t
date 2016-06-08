#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::NoWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use Math::Util::CalculatedValue::Validatable;

subtest 'amount type is payout' => sub {
    my $c = produce_contract({
        underlying            => 'R_100',
        bet_type              => 'CALL',
        barrier               => 'S0P',
        duration              => '1h',
        currency              => 'USD',
        amount_type           => 'payout',
        amount                => 10,
        app_markup_percentage => 1,          # 1%
    });

    is $c->amount_type, 'payout', 'amount_type is payout';
    is $c->app_markup->amount, 0.01, 'correct markup amount';
    is $c->app_markup_dollar_amount, 0.1, 'correct dollar amount';
};

subtest 'amount type is stake' => sub {
    BOM::Platform::Runtime->instance->app_config->quants->commission->adjustment->global_scaling(100);
    my $fake_theo = Math::Util::CalculatedValue::Validatable->new({
        name        => 'theo_probability',
        description => 'fake theo',
        set_by      => 'test',
        base_amount => 0.5
    });
    my $c = produce_contract({
        underlying            => 'R_100',
        bet_type              => 'CALL',
        barrier               => 'S0P',
        duration              => '1h',
        currency              => 'USD',
        amount_type           => 'stake',
        amount                => 10,
        app_markup_percentage => 1,            # 1%
        base_commission       => 0,
        theo_probability      => $fake_theo,
    });

    is $c->amount_type, 'stake', 'amount_type is stake';
    is $c->app_markup->amount, 0.01, 'correct markup amount';
    is $c->app_markup_dollar_amount, 0.2, 'correct dollar amount';
};
