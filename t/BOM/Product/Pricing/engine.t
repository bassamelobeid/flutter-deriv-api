use strict;
use warnings;

use Test::Most;
use Scalar::Util qw( looks_like_number );
use Test::Warnings;
use Test::MockModule;
use File::Spec;

use Date::Utility;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis;
use Pricing::Engine::EuropeanDigitalSlope;

my $date_pricing = 1352344145;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $date_pricing});
my $mocked = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked->mock(
    'get',
    sub {
        [map { {epoch => $_, decimate_epoch => $_, quote => 100 + 0.005 * $_} } (0 .. 80)];
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new($date_pricing),
    }) for (qw/GBP JPY USD AUD EUR JPY-USD/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('correlation_matrix', {recorded_date => Date::Utility->new($date_pricing)});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => 'FCHI',
        recorded_date => Date::Utility->new($date_pricing),
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new($date_pricing),
    }) for qw/frxUSDJPY frxGBPJPY frxGBPUSD/;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'FCHI',
        recorded_date => Date::Utility->new($date_pricing),
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
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

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
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

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
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

my $current_tick = Postgres::FeedDB::Spot::Tick->new({
    underlying => 'frxUSDJPY',
    epoch      => 1352344145,
    quote      => 76,
});
my %bet_params = (
    bet_type     => 'CALL',
    date_pricing => '1352344145',
    date_start   => '1352344145',
    date_expiry  => '12-Nov-12',
    underlying   => 'frxUSDJPY',
    current_tick => $current_tick,
    payout       => 100,
    currency     => 'GBP',
);
my $ot = produce_contract({
    %bet_params,
    barrier  => 77,
    bet_type => 'ONETOUCH'
});
$bet_params{underlying} = 'FCHI';
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
$bet_params{underlying}  = 'FCHI';
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
    my $engine = BOM::Product::Pricing::Engine::Intraday::Forex->new(bet => $short_term);

    isa_ok($engine->probability, 'Math::Util::CalculatedValue::Validatable', 'probability');
    done_testing;
};

subtest 'Slope' => sub {
    plan tests => 6;

    ok $expiry_range->ask_probability->amount > 0, 'probability > 0';
    ok $expiry_range->ask_probability->amount < 1, 'probability < 1';
    #We expect risk_markup, CALL and PUT
    is scalar keys %{$expiry_range->debug_information}, 4;
    ok exists $expiry_range->debug_information->{CALL};
    ok exists $expiry_range->debug_information->{PUT};
    ok exists $expiry_range->debug_information->{risk_markup};
};

done_testing;
