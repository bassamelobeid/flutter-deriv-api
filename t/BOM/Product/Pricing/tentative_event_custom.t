use strict;
use warnings;

use Time::HiRes;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::Most qw(-Test::Deep);
use Test::Warnings;
use JSON qw(decode_json);
use Date::Utility;

use Postgres::FeedDB::Spot::Tick;
use LandingCompany::Offerings qw(reinitialise_offerings);

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::MarketData qw(create_underlying);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);
initialize_realtime_ticks_db();

my $now = Date::Utility->new('2016-03-18 05:00:00');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now,
    }) for (qw/USD EUR EUR-USD/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxEURUSD',
        recorded_date => $now,
    });

set_absolute_time($now->epoch);

my $blackout_start_15m = $now->minus_time_interval('30m');
my $blackout_end_15m   = $now->minus_time_interval('15m');

my $blackout_start_2h = $now->minus_time_interval('3h');
my $blackout_end_2h   = $now->minus_time_interval('1h');

my $events         = [{
        symbol                => 'USD',
        release_date          => $now->epoch,
        blankout              => $blackout_start_15m->epoch,
        estimated_release_date => $now->epoch,
        blankout_end          => $blackout_end_15m->epoch,
        is_tentative          => 1,
        tentative_event_shift => 0.02,
        event_name            => 'Test tentative',
        impact                => 5,
    },
    {
        symbol                => 'EUR',
        release_date          => $now->epoch,
        blankout              => $blackout_start_2h->epoch,
        estimated_release_date => $now->epoch,
        blankout_end          => $blackout_end_2h->epoch,
        is_tentative          => 1,
        tentative_event_shift => 0.01,
        event_name            => 'Test tentative',
        impact                => 5,
    }
    ];
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        recorded_date => $now,
        events        => $events,
    });

Volatility::Seasonality::generate_economic_event_seasonality({
    underlying_symbols => ['frxEURUSD'],
    economic_events    => $events,
    chronicle_writer   => BOM::Platform::Chronicle::get_chronicle_writer,
    date               => $now,
});

my $contract_args = {
    underlying   => 'frxEURUSD',
    barrier      => 'S0P',
    duration     => '1h',
    payout       => 100,
    currency     => 'USD',
    date_pricing => $now,
    date_start   => $now,
    current_tick => Postgres::FeedDB::Spot::Tick->new({
            symbol => 'frxEURUSD',
            epoch  => $now->epoch,
            quote  => 100,
        })};

#key is "contract type_pip diff" and value is expected barrier(s)
my $expected = {
    'CALL_0'        => 55.48,
    'CALL_1000'     => 52.12,
    'NOTOUCH_0'     => 5.51,
    'NOTOUCH_1000'  => 16.92,
    'ONETOUCH_2000' => 97.05,
    'PUT_1000'      => 59.99,
    'PUT_0'         => 55.52
};

my $underlying = create_underlying('frxEURUSD');
my $module     = Test::MockModule->new('Quant::Framework::Underlying');
$module->mock('spot_tick', sub { $contract_args->{current_tick} });

# First we test contract which is outside the event.

foreach my $key (sort { $a cmp $b } keys %{$expected}) {
    my ($bet_type, $pip_diff) = split '_', $key;

    $contract_args->{bet_type}            = $bet_type;
    $contract_args->{barrier}             = 'S' . $pip_diff . 'P';
    $contract_args->{pricing_engine_name} = 'BOM::Product::Pricing::Engine::Intraday::Forex';
    $contract_args->{landing_company}     = 'japan';
    $contract_args->{pricing_vol} = 0.1; # not testing vol here
    my $c = produce_contract($contract_args);
    cmp_ok $c->ask_price, '==', $expected->{$key}, "correct ask price for $key";
    is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', "correct engine for $key";
}

# Now test pricing for contracts within the tentative events
$blackout_start_15m = $now->minus_time_interval('15m');
$blackout_end_15m   = $now->plus_time_interval('15m');

my $blackout_start_4h = $now->minus_time_interval('2h');
my $blackout_end_4h   = $now->plus_time_interval('2h');

my $another_events         = [{
        symbol                => 'USD',
        release_date          => $now->epoch,
        blankout              => $blackout_start_15m->epoch,
        estimated_release_date => $now->epoch,
        blankout_end          => $blackout_end_15m->epoch,
        is_tentative          => 1,
        tentative_event_shift => 0.02,
        event_name            => 'Another Test tentative',
        impact                => 5,
    },
    {
        symbol                => 'EUR',
        release_date          => $now->epoch,
        blankout              => $blackout_start_4h->epoch,
        estimated_release_date => $now->epoch,
        blankout_end          => $blackout_end_4h->epoch,
        is_tentative          => 1,
        tentative_event_shift => 0.01,
        event_name            => 'Another Test tentative',
        impact                => 5,
    }
    ];


BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        recorded_date => $now,
        events        => $another_events,
    });

my $expected_with_event = {
    'CALL_0'        => 55.48,
    'CALL_1000'     => 61.17,
    'NOTOUCH_0'     => 5.51,
    'NOTOUCH_1000'  => 35.62,
    'ONETOUCH_2000' => 100,
    'PUT_1000'      => 68.83,
    'PUT_0'         => 55.52
};

foreach my $key (sort { $a cmp $b } keys %{$expected_with_event}) {
    my ($bet_type, $pip_diff) = split '_', $key;

    $contract_args->{bet_type}            = $bet_type;
    $contract_args->{barrier}             = 'S' . $pip_diff . 'P';
    $contract_args->{pricing_engine_name} = 'BOM::Product::Pricing::Engine::Intraday::Forex';
    $contract_args->{landing_company}     = 'japan';
    $contract_args->{pricing_vol} = 0.1; # not testing vol here
    my $c = produce_contract($contract_args);
    cmp_ok $c->ask_price, '==', $expected_with_event->{$key}, "correct ask price for $key";
    is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', "correct engine for $key";
}

done_testing();

