#!/etc/rmg/bin/perl

use strict;
use warnings;

use Format::Util::Numbers qw(roundnear);
use Test::MockModule;
use BOM::Product::ContractFactory qw(produce_contract);
use Test::More tests => 5;
use Math::Util::CalculatedValue::Validatable;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use Date::Utility;

#create an empty un-used even so ask_price won't fail preparing market data for pricing engine
#Because the code to prepare market data is called for all pricings in Contract
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]});

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(USD JPY EUR EUR-USD USD-JPY XAU GBP);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(frxEURUSD frxUSDJPY frxXAUUSD frxGBPUSD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => $_,
        recorded_date => $now,
    }) for qw(FCHI FTSE);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => $_,
        recorded_date => $now,
    }) for qw(FCHI FTSE);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('correlation_matrix');

subtest 'payout' => sub {
    my $payout                = 10;
    my $min_commission_markup = 0.02 / $payout;
    my $c                     = produce_contract({
        bet_type        => 'CALL',
        underlying      => 'R_100',
        barrier         => 'S0P',
        duration        => '10m',
        currency        => 'USD',
        payout          => $payout,
        base_commission => 0.001,
    });
    is $c->commission_markup->amount, $min_commission_markup, 'commission_markup amount is floored 0.002 when payout is 10';
};

subtest 'stake' => sub {
    my $mocked           = Test::MockModule->new('BOM::Product::Contract::Call');
    my $stake            = 0.5;
    my $base_commission  = 0;
    my $theo_probability = Math::Util::CalculatedValue::Validatable->new({
        name        => 'theo_probability',
        description => 'test theo',
        set_by      => 'test',
        base_amount => 0.5,
    });
    my $c = produce_contract({
        bet_type         => 'CALL',
        underlying       => 'R_100',
        barrier          => 'S0P',
        duration         => '10m',
        currency         => 'USD',
        amount_type      => 'stake',
        amount           => $stake,
        theo_probability => $theo_probability,
        base_commission  => $base_commission,
    });
    is $c->payout, 0.96, 'payout is re-adjusted to 0.96 to get a minimum commission of 2 cents';

    $theo_probability = Math::Util::CalculatedValue::Validatable->new({
        name        => 'theo_probability',
        description => 'test theo',
        set_by      => 'test',
        base_amount => 0.015,
    });
    $c = produce_contract({
        bet_type         => 'CALL',
        underlying       => 'R_100',
        barrier          => 'S0P',
        duration         => '10m',
        currency         => 'USD',
        amount_type      => 'stake',
        amount           => $stake,
        theo_probability => $theo_probability,
        base_commission  => $base_commission,
    });

    is $c->payout, 20, "Random's payout is re-adjusted to 20 as corresponds to minimum ask prob of " . $c->market->deep_otm_threshold;

    $c = produce_contract({
        bet_type         => 'CALL',
        underlying       => 'frxUSDJPY',
        barrier          => 'S0P',
        duration         => '10m',
        currency         => 'USD',
        amount_type      => 'stake',
        amount           => $stake,
        theo_probability => $theo_probability,
        base_commission  => $base_commission,
    });

    is $c->payout, 10, "Forex's payout is re-adjusted to 10 as corresponds to minimum ask prob of " . $c->market->deep_otm_threshold;

    $c = produce_contract({
        bet_type         => 'CALL',
        underlying       => 'frxXAUUSD',
        barrier          => 'S0P',
        duration         => '10m',
        currency         => 'USD',
        amount_type      => 'stake',
        amount           => $stake,
        theo_probability => $theo_probability,
        base_commission  => $base_commission,
    });

    is $c->payout, 5, "Commodities' payout is re-adjusted to 5 as corresponds to minimum ask prob of " . $c->market->deep_otm_threshold;

    $c = produce_contract({
        bet_type         => 'CALL',
        underlying       => 'GDAXI',
        barrier          => 'S0P',
        duration         => '10m',
        currency         => 'USD',
        amount_type      => 'stake',
        amount           => $stake,
        theo_probability => $theo_probability,
        base_commission  => $base_commission,
    });

    is $c->payout, 5, "Indices' payout is re-adjusted to 5 as corresponds to minimum ask prob of " . $c->market->deep_otm_threshold;

    $c = produce_contract({
        bet_type         => 'CALL',
        underlying       => 'USMSFT',
        barrier          => 'S0P',
        duration         => '10m',
        currency         => 'USD',
        amount_type      => 'stake',
        amount           => $stake,
        theo_probability => $theo_probability,
        base_commission  => $base_commission,
    });

    is $c->payout, 5, "Stocks' payout is re-adjusted to 5 as corresponds to minimum ask prob of " . $c->market->deep_otm_threshold;

};

subtest 'new commission structure' => sub {
    my $fake_risk = Math::Util::CalculatedValue::Validatable->new({
        name        => 'risk_markup',
        description => 'test total markup',
        set_by      => 'test',
        base_amount => 0.01,
    });
    my $base_commission = 0.02;
    my %test_cases      = (
        0.5 => [{
                stake  => 520,
                payout => 981.132,
            },
            {
                stake  => 540,
                payout => 1018.853,
            },
            {
                stake  => 27000,
                payout => 49123.23,
            },
            {
                stake  => 28000,
                payout => 50909.09,
            },
        ],
        0.75 => [{
                stake  => 900,
                payout => 1153.846,
            },
            {
                stake  => 1000,
                payout => 1281.99,
            },
            {
                stake  => 46000,
                payout => 57525.35,
            },
            {
                stake  => 47000,
                payout => 58750,
            },
        ],
    );

    foreach my $theo (keys %test_cases) {
        my $fake_theo = Math::Util::CalculatedValue::Validatable->new({
            name        => 'theo_probability',
            description => 'test theo',
            set_by      => 'test',
            base_amount => $theo + $fake_risk->amount,
        });
        foreach my $data (@{$test_cases{$theo}}) {
            my $stake = $data->{stake};
            my $c     = produce_contract({
                bet_type         => 'CALL',
                underlying       => 'R_100',
                barrier          => 'S0P',
                duration         => '10m',
                currency         => 'USD',
                amount_type      => 'stake',
                amount           => $stake,
                base_commission  => $base_commission,
                theo_probability => $fake_theo,
            });
            is $c->payout, roundnear(0.01, $data->{payout}), 'correct payout amount';
        }
    }
};

subtest 'commission for japan' => sub {
    my $fake_theo = Math::Util::CalculatedValue::Validatable->new({
        name        => 'theo_probability',
        description => 'test theo',
        set_by      => 'test',
        base_amount => 0.5,
    });
    my $args = {
        bet_type         => 'CALL',
        underlying       => 'R_100',
        barrier          => 'S0P',
        duration         => '1d',
        amount           => 100000,
        amount_type      => 'payout',
        currency         => 'JPY',
        theo_probability => $fake_theo,
    };
    my $c = produce_contract($args);
    is $c->commission_markup->amount, $c->base_commission, 'at 100,000 yen commission markup is base commission';
    $args->{amount} = 100001;
    $c = produce_contract($args);
    ok $c->commission_markup->amount > $c->base_commission, 'at 100,000 yen commission markup is more than base commission';
};

sub test_flexible_commission {
    my ($symbol, $market, $scaling) = @_;

    my $args = {
        bet_type    => 'CALL',
        underlying  => $symbol,
        barrier     => 'S0P',
        duration    => '1d',
        amount      => 1000,
        amount_type => 'payout',
        currency    => 'USD',
    };

    BOM::Platform::Runtime->instance->app_config->quants->commission->adjustment->per_market_scaling->$market(100);
    my $c = produce_contract($args);
    is $c->commission_markup->amount, $c->base_commission, "correct commission markup without scaling for $symbol" . $c->commission_markup->amount;
    my $original_commission = $c->commission_markup->amount;

    BOM::Platform::Runtime->instance->app_config->quants->commission->adjustment->per_market_scaling->$market($scaling);
    $c = produce_contract($args);
    if ($scaling == 10000) {
        is $c->ask_price, 1000, "max ask price when commissoin scaling is max for $symbol";
    } else {
        is $c->commission_markup->amount, $original_commission * ($scaling / 100), "correct commission markup with $scaling scaling for $symbol";
    }
}

subtest 'flexible commission check for different markets' => sub {
    test_flexible_commission 'R_100',     'volidx',      50;
    test_flexible_commission 'frxEURUSD', 'forex',       30;
    test_flexible_commission 'frxUSDJPY', 'forex',       70;
    test_flexible_commission 'frxXAUUSD', 'commodities', 70;
    test_flexible_commission 'FCHI',      'indices',     170;
    test_flexible_commission 'FTSE',      'indices',     25;

    test_flexible_commission 'R_100',     'volidx',      10000;
    test_flexible_commission 'frxEURUSD', 'forex',       10000;
    test_flexible_commission 'frxUSDJPY', 'forex',       10000;
    test_flexible_commission 'frxXAUUSD', 'commodities', 10000;
    test_flexible_commission 'FCHI',      'indices',     10000;
    test_flexible_commission 'FTSE',      'indices',     10000;
};

