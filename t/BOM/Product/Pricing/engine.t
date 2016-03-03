use strict;
use warnings;

use Test::Most;
use Scalar::Util qw( looks_like_number );
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use Date::Utility;
use BOM::Test::Runtime qw(:normal);
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis;
use Pricing::Engine::EuropeanDigitalSlope;

my $date_pricing = 1352344145;

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new($date_pricing),
    }) for (qw/GBP JPY USD AUD EUR JPY-USD/);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'index',
    {
        symbol        => 'FTSE',
        recorded_date => Date::Utility->new($date_pricing),
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new($date_pricing),
    }) for qw/frxUSDJPY frxGBPJPY frxGBPUSD/;

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'FTSE',
        recorded_date => Date::Utility->new($date_pricing),
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => 'GBP',
        rates  => {
            1   => 0.2,
            2   => 0.15,
            7   => 0.18,
            32  => 0.25,
            62  => 0.2,
            92  => 0.18,
            186 => 0.1,
            365 => 0.13,
        },
        type          => 'implied',
        implied_from  => 'USD',
        recorded_date => Date::Utility->new($date_pricing),
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => 'JPY',
        rates  => {
            1   => 0.2,
            2   => 0.15,
            7   => 0.18,
            32  => 0.25,
            62  => 0.2,
            92  => 0.18,
            186 => 0.1,
            365 => 0.13,
        },
        type          => 'implied',
        implied_from  => 'USD',
        recorded_date => Date::Utility->new($date_pricing),
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => 'AUD',
        rates  => {
            1   => 0.2,
            2   => 0.15,
            7   => 0.18,
            32  => 0.25,
            62  => 0.2,
            92  => 0.18,
            186 => 0.1,
            365 => 0.13,
        },
        type          => 'implied',
        implied_from  => 'EUR',
        recorded_date => Date::Utility->new($date_pricing),
    });

my %bet_params = (
    bet_type     => 'CALL',
    date_pricing => '1352344145',
    date_start   => '1352344145',
    date_expiry  => '12-Nov-12',
    underlying   => 'frxUSDJPY',
    current_spot => 76,
    payout       => 100,
    currency     => 'GBP',
);
my $ot = produce_contract({
    %bet_params,
    barrier  => 77,
    bet_type => 'ONETOUCH'
});
$bet_params{underlying} = 'FTSE';
my $equity_call = produce_contract({
    %bet_params,
    barrier  => 77,
    bet_type => 'ONETOUCH'
});
$bet_params{bet_type} = 'EXPIRYRANGE';
my $expiry_range = produce_contract({
    %bet_params,
    high_barrier => 77,
    low_barrier  => 75
});
$bet_params{bet_type} = 'RANGE';
my $range = produce_contract({
    %bet_params,
    high_barrier => 77,
    low_barrier  => 75
});
$bet_params{underlying}  = 'frxUSDJPY';
$bet_params{bet_type}    = 'CALL';
$bet_params{date_expiry} = '1352345145';
my $short_term = produce_contract({%bet_params, barrier => 77});
$bet_params{underlying}  = 'FTSE';
$bet_params{bet_type}    = 'RANGE';       # This test sucks.
$bet_params{date_expiry} = '12-Nov-12';

subtest 'VannaVolga' => sub {
    plan tests => 7;

    my $engine = BOM::Product::Pricing::Engine::VannaVolga->new(bet => $ot);

    ok(looks_like_number($engine->alpha), 'Engine alpha looks reasonable.');
    ok(looks_like_number($engine->beta),  'Engine beta looks reasonable.');
    ok(looks_like_number($engine->gamma), 'Engine gamma looks reasonable.');

    isa_ok($engine->vanna_correction, 'Math::Util::CalculatedValue::Validatable', 'vanna_correction isa CalcVal.');
    isa_ok($engine->volga_correction, 'Math::Util::CalculatedValue::Validatable', 'volga_correction isa CalcVal.');
    isa_ok($engine->vega_correction,  'Math::Util::CalculatedValue::Validatable', 'vega_correction isa CalcVal.');

    $engine = BOM::Product::Pricing::Engine::VannaVolga->new(bet => $equity_call);
    is(ref $engine->priced_portfolios, 'HASH', 'portfolio_hedge looks reasonable.');
};

subtest 'VannaVolga::Calibrated' => sub {
    plan tests => 8;

    foreach my $calibration_model (qw( bloomberg wystup bom-surv bom-fet )) {
        my $engine = BOM::Product::Pricing::Engine::VannaVolga::Calibrated->new(
            bet               => $range,
            calibration_model => $calibration_model
        );

        my $survival_weight = $engine->survival_weight;

        is(ref $survival_weight, 'HASH', "survival_weight of $calibration_model is a HashRef.");
        cmp_deeply(
            [sort keys %{$survival_weight}],
            [qw(survival_probability vanna vega volga)],
            "survival_weight of $calibration_model has correct keys."
        );
    }
};

subtest 'Intraday::Forex' => sub {
    plan tests => 3;

    my $engine = BOM::Product::Pricing::Engine::Intraday::Forex->new(bet => $short_term);

    isa_ok($engine->intraday_delta_correction, 'Math::Util::CalculatedValue::Validatable', 'intraday_delta_correction');
    isa_ok($engine->intraday_vega_correction,  'Math::Util::CalculatedValue::Validatable', 'intraday_vega_correction');
    isa_ok($engine->probability,               'Math::Util::CalculatedValue::Validatable', 'probability');

};

subtest 'Slope' => sub {
    plan tests => 6;

    my %params = map { $_ => $expiry_range->_pricing_parameters->{$_} } @{Pricing::Engine::EuropeanDigitalSlope->required_args};
    my $engine = Pricing::Engine::EuropeanDigitalSlope->new(%params);

    ok $engine->theo_probability > 0, 'probability > 0';
    ok $engine->theo_probability < 1, 'probability < 1';
    is scalar keys %{$engine->debug_information}, 3;
    ok exists $engine->debug_information->{CALL};
    ok exists $engine->debug_information->{PUT};
    ok exists $engine->debug_information->{discounted_probability};
};

sub _surface_with_10_deltas {

    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_delta',
        {
            symbol  => 'frxEURAUD',
            surface => {
                7 => {
                    smile => {
                        10 => 0.22,
                        25 => 0.21,
                        50 => 0.2,
                        75 => 0.211,
                        90 => 0.221
                    },
                    vol_spread => {
                        50 => 0.1,
                    }
                },
                30 => {
                    smile => {
                        10 => 0.22,
                        25 => 0.21,
                        50 => 0.2,
                        75 => 0.211,
                        90 => 0.221
                    },
                    vol_spread => {50 => 0.1}
                },
                365 => {
                    smile => {
                        10 => 0.22,
                        25 => 0.21,
                        50 => 0.2,
                        75 => 0.211,
                        90 => 0.221
                    },
                    vol_spread => {50 => 0.1}
                },
            },
        });
}

done_testing;
