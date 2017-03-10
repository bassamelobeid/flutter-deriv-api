use strict;
use warnings;

use Time::HiRes;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::Most qw(-Test::Deep);
use Format::Util::Numbers qw(roundnear);
use Test::FailWarnings;
use JSON qw(decode_json);
use BOM::Product::ContractFactory qw(produce_contract);
use Postgres::FeedDB::Spot::Tick;
use Date::Utility;
use BOM::MarketData qw(create_underlying);
use LandingCompany::Offerings qw(reinitialise_offerings);

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

my $blackout_start = $now->minus_time_interval('1h');
my $blackout_end   = $now->plus_time_interval('1h');
my $events = [{
                symbol                => 'USD',
                release_date          => $now->epoch,
                blankout              => $blackout_start->epoch,
                blankout_end          => $blackout_end->epoch,
                is_tentative          => 1,
                tentative_event_shift => 0.02,
                event_name            => 'Test tentative',
                impact                => 5,
            },
            {
                symbol                => 'EUR',
                release_date          => $now->epoch,
                blankout              => $blackout_start->epoch,
                blankout_end          => $blackout_end->epoch,
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

Volatility::Seasonality->new(
    chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader,
    chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer,
)->generate_economic_event_seasonality({underlying_symbol => 'frxEURUSD', economic_events => $events});

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
    'CALL_0'        => 55.27,
    'CALL_1000'     => 64.75,
    'NOTOUCH_0'     => 5.28,
    'NOTOUCH_1000'  => 45.18,
    'ONETOUCH_2000' => 100,
    'PUT_1000'      => 73.93,
    'PUT_0'         => 55.3,
};

my $underlying = create_underlying('frxEURUSD');
my $module     = Test::MockModule->new('Quant::Framework::Underlying');
$module->mock('spot_tick', sub { $contract_args->{current_tick} });

foreach my $key (sort { $a cmp $b } keys %{$expected}) {
    my ($bet_type, $pip_diff) = split '_', $key;

    $contract_args->{bet_type}            = $bet_type;
    $contract_args->{barrier}             = 'S' . $pip_diff . 'P';
    $contract_args->{pricing_engine_name} = 'BOM::Product::Pricing::Engine::Intraday::Forex';
    $contract_args->{landing_company}     = 'japan';

    my $c = produce_contract($contract_args);

    is $c->ask_price, $expected->{$key}, "correct ask price for $key";
    is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', "correct engine for $key";
}

done_testing();

