use strict;
use warnings;

use Test::Most;
use Test::Warnings qw/warning/;

use Date::Utility;
use Postgres::FeedDB::Spot::Tick;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Test::MockModule;

my $mocked_decimate = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked_decimate->mock(
    'get',
    sub {
        [map { {epoch => $_, decimate_epoch => $_, quote => 100 + 0.005 * $_} } (0 .. 80)];
    });
initialize_realtime_ticks_db();

use BOM::Product::ContractFactory qw( produce_contract );

my $now = Date::Utility->new('7-Jan-14 12:00');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now->minus_time_interval('10m'),
    }) for (qw/JPY USD JPY-USD/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now->minus_time_interval('10m'),
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        recorded_date => $now->minus_time_interval('10m'),
        events        => [{
                symbol       => 'USD',
                release_date => $now->epoch,
                event_name   => 'Change in Nonfarm Payrolls',
                vol_change   => 0.5,
            }]
    },
);

my $params = {
    bet_type     => 'CALL',
    underlying   => 'frxUSDJPY',
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

my $amount;
warning_like {
    $amount = $bet->pricing_engine->event_markup->amount;
}
qr/basis tick/, 'warns';

is($bet->pricing_engine->economic_events_spot_risk_markup->amount, 0.01, 'correct spot risk markup');
cmp_ok($amount, '<', $bet->pricing_engine->economic_events_spot_risk_markup->amount, 'vol risk markup is lower than higher range');
is($bet->pricing_engine->economic_events_markup->amount, 0.01, 'economic events markup is max of spot or vol risk markup');

done_testing;
