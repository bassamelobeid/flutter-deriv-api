use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use File::Spec;
use JSON qw(decode_json);

use Cache::RedisDB;
use Date::Utility;
use BOM::Market::Data::Tick;
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

use BOM::Product::ContractFactory qw( produce_contract );

my $now = Date::Utility->new('7-Jan-14 12:00');

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now->minus_time_interval('10m'),
    }) for (qw/JPY USD GBP JPY-USD GBP-USD GBP-JPY/);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now->minus_time_interval('10m'),
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxGBPJPY',
        recorded_date => $now->minus_time_interval('10m'),
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxGBPUSD',
        recorded_date => $now->minus_time_interval('10m'),
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
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

test_economic_events_markup(0.0122153991947796,  0.0122153991947796,  'frxUSDJPY');
test_economic_events_markup(0.00884422105306016, 0.00884422105306016, 'frxGBPUSD');
test_economic_events_markup(0.00880771221334573, 0.00880771221334573, 'frxGBPJPY');

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
    cmp_ok(
        $bet->pricing_engine->economic_events_volatility_risk_markup->amount,
        '<',
        $bet->pricing_engine->economic_events_spot_risk_markup->amount,
        'vol risk markup is lower than higher range'
    );
    is($bet->pricing_engine->economic_events_markup->amount, $expected_ee_markup, 'economic events markup is max of spot or vol risk markup');
}

done_testing;
