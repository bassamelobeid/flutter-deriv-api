use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::Warnings qw/warning/;
use File::Spec;
use JSON qw(decode_json);
use Cache::RedisDB;
use Date::Utility;

use LandingCompany::Offerings qw(reinitialise_offerings);
use Postgres::FeedDB::Spot::Tick;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Platform::Chronicle;

reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);
initialize_realtime_ticks_db();

use BOM::Product::ContractFactory qw( produce_contract );

my $now = Date::Utility->new('7-Jan-14 12:00');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now->minus_time_interval('10m'),
    }) for (qw/JPY USD GBP JPY-USD GBP-USD GBP-JPY/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now->minus_time_interval('10m'),
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxGBPJPY',
        recorded_date => $now->minus_time_interval('10m'),
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxGBPUSD',
        recorded_date => $now->minus_time_interval('10m'),
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        recorded_date => $now->minus_time_interval('3h'),
        events        => [{
                symbol       => 'USD',
                release_date => $now->minus_time_interval('3h')->epoch,
                impact       => 5,
                event_name   => 'Unemployment Rate',
            },
            {
                symbol       => 'USD',
                release_date => $now->epoch,
                impact       => 5,
                event_name   => 'Unemployment Rate',
            }
        ],
    },
);

# we don't use it. should it be removed?
#Volatility::Seasonality::generate_economic_event_seasonality({
#    underlying_symbols => [qw(frxUSDJPY frxGBPUSD frxGBPJPY)],
#    chronicle_writer   => BOM::Platform::Chronicle::get_chronicle_writer,
#    economic_events    => [],
#    date               => $now,
#});

test_economic_events_markup(0.01,  0.01,  'frxUSDJPY');
test_economic_events_markup(0.01, 0.01, 'frxGBPUSD');
test_economic_events_markup(0.01, 0.01, 'frxGBPJPY');

sub test_economic_events_markup {
    my ($expected_ee_srmarkup, $expected_ee_markup, $underlying) = @_;

    my $params = {
        bet_type     => 'CALL',
        underlying   => $underlying,
        current_spot => 100,
        barrier      => 100.011,
        date_start   => $now->minus_time_interval('10m'),
        duration     => '1h',
        currency     => 'USD',
        payout       => 100,
        date_pricing => $now->minus_time_interval('10m'),
    };

    my $bet = produce_contract($params);
    is($bet->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'uses Intraday Historical pricing engine');
    is($bet->pricing_engine->economic_events_spot_risk_markup->amount, $expected_ee_srmarkup, 'correct spot risk markup');

    my $amount;
    like(
        warning { $amount = $bet->pricing_engine->economic_events_volatility_risk_markup->amount },
        qr/No basis tick for/,
        'Got warning for no basis tick'
    );
    cmp_ok($amount, '<', $bet->pricing_engine->economic_events_spot_risk_markup->amount, 'vol risk markup is lower than higher range');
    is($bet->pricing_engine->economic_events_markup->amount, $expected_ee_markup, 'economic events markup is max of spot or vol risk markup');
}

done_testing;
