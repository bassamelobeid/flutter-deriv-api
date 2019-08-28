#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 5;
use Test::Warnings;

use BOM::Product::ContractFactory qw(produce_contract);
use Math::Util::CalculatedValue::Validatable;

BOM::Config::Runtime->instance->app_config->quants->commission->adjustment->per_market_scaling->synthetic_index(100);
my $fake_theo = Math::Util::CalculatedValue::Validatable->new({
    name        => 'theo_probability',
    description => 'fake theo',
    set_by      => 'test',
    base_amount => 0.5
});

subtest 'app markup amount' => sub {
    my $c2 = produce_contract({
        underlying            => 'R_100',
        bet_type              => 'CALL',
        barrier               => 'S0P',
        duration              => '1h',
        currency              => 'USD',
        amount_type           => 'stake',
        amount                => 10,
        app_markup_percentage => 1,            # 1%
        base_commission       => 0.02,
        theo_probability      => $fake_theo,
    });

    is $c2->app_markup->amount, 0.01, 'correct markup amount';
    is $c2->payout + 0, 18.87, 'correct payout';
    is $c2->app_markup_dollar_amount, 0.19, 'correct dollar amount';

    my $c = produce_contract({
        underlying            => 'R_100',
        bet_type              => 'CALL',
        barrier               => 'S0P',
        duration              => '1h',
        currency              => 'USD',
        amount_type           => 'payout',
        amount                => $c2->payout,
        app_markup_percentage => 1,             # 1%
        base_commission       => 0.02,
    });

    is $c->app_markup->amount, 0.01, 'correct markup amount';
    is $c->app_markup_dollar_amount, 0.19, 'correct dollar amount';

};

subtest 'price check for 1 x base_commission' => sub {
    my $c = produce_contract({
        underlying            => 'R_100',
        bet_type              => 'CALL',
        barrier               => 'S0P',
        duration              => '1h',
        currency              => 'USD',
        amount_type           => 'stake',
        amount                => 50,
        app_markup_percentage => 1,            # 1%
        base_commission       => 0.02,
        theo_probability      => $fake_theo,
    });

    my $c2 = produce_contract({
        underlying            => 'R_100',
        bet_type              => 'CALL',
        barrier               => 'S0P',
        duration              => '1h',
        currency              => 'USD',
        amount_type           => 'payout',
        amount                => $c->payout,
        app_markup_percentage => 1,            # 1%
        base_commission       => 0.02,
        theo_probability      => $fake_theo,
    });
    is $c2->ask_price + 0, 50, 'matched ask_price';
};

subtest 'price check for 2 x base_commission' => sub {
    my $c = produce_contract({
        underlying            => 'R_100',
        bet_type              => 'CALL',
        barrier               => 'S0P',
        duration              => '1h',
        currency              => 'USD',
        amount_type           => 'stake',
        amount                => 30000,
        app_markup_percentage => 1,            # 1%
        base_commission       => 0.02,
        theo_probability      => $fake_theo,
    });

    my $c2 = produce_contract({
        underlying            => 'R_100',
        bet_type              => 'CALL',
        barrier               => 'S0P',
        duration              => '1h',
        currency              => 'USD',
        amount_type           => 'payout',
        amount                => $c->payout,
        app_markup_percentage => 1,            # 1%
        base_commission       => 0.02,
        theo_probability      => $fake_theo,
    });
    is $c2->ask_price + 0, 30000, 'matched ask_price';
};

subtest 'price check for 1 to 2 x base_commission' => sub {
    my $c = produce_contract({
        underlying            => 'R_100',
        bet_type              => 'CALL',
        barrier               => 'S0P',
        duration              => '1h',
        currency              => 'USD',
        amount_type           => 'stake',
        amount                => 15000,
        app_markup_percentage => 1,            # 1%
        base_commission       => 0.02,
        theo_probability      => $fake_theo,
    });

    my $c2 = produce_contract({
        underlying            => 'R_100',
        bet_type              => 'CALL',
        barrier               => 'S0P',
        duration              => '1h',
        currency              => 'USD',
        amount_type           => 'payout',
        amount                => $c->payout,
        app_markup_percentage => 1,            # 1%
        base_commission       => 0.02,
        theo_probability      => $fake_theo,
    });
    is $c2->ask_price + 0, 15000, 'matched ask_price';
};
