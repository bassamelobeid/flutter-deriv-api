use strict;
use warnings;

use Test::Most 0.22 (tests => 53);
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Runtime qw(:normal);
use BOM::Market::AggTicks;
use Date::Utility;
use Format::Util::Numbers qw( roundnear );
use BOM::Product::ContractFactory qw( produce_contract );

use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

BOM::Market::AggTicks->new->flush;

BOM::Platform::Runtime->instance->app_config->system->directory->feed('/home/git/regentmarkets/bom/t/data/feed/');
BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('frxUSDJPY/8-Nov-12.dump');

my $date_start   = 1352345145;
my $date_pricing = $date_start;
my $date_expiry  = $date_start + 1000;
my $symbol       = 'frxUSDJPY';
my $barrier      = 'S3P';
my $barrier_low  = 'S-3P';
my $payout       = 100;
my $currency     = 'GBP';

my $recorded_date = Date::Utility->new($date_start)->truncate_to_day;

foreach my $symbol (qw(NYSE LSE SES FOREX)) {
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'exchange',
        {
            symbol        => $symbol,
            recorded_date => $recorded_date,
            date          => Date::Utility->new,
        });
}

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol           => 'FSE',
        trading_timezone => 'Europe/Berlin',
        market_times     => {
            standard => {
                daily_close      => '16h30m',
                daily_open       => '8h',
                daily_settlement => '19h30m',
            },
            partial_trading => {
                dst_open       => '7h',
                dst_close      => '12h',
                standard_open  => '8h',
                standard_close => '13h',
            },
            dst => {
                daily_close      => '15h30m',
                daily_open       => '7h',
                daily_settlement => '18h30m',
            },
        },
        date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol           => 'NASDAQ',
        trading_timezone => 'America/New_York',
        market_times     => {
            standard => {
                daily_close      => '21h',
                daily_open       => '14h30m',
                daily_settlement => '23h59m59s',
            },
            partial_trading => {
                dst_open       => '13h30m',
                dst_close      => '17h',
                standard_open  => '14h30m',
                standard_close => '18h',
            },
            dst => {
                daily_close      => '20h',
                daily_open       => '13h30m',
                daily_settlement => '23h59m59s',
            },
        },
        date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol           => 'ASX',
        trading_timezone => 'Australia/Sydney',
        market_times     => {
            standard => {
                daily_close      => '6h',
                daily_open       => '0s',
                daily_settlement => '9h',
            },
            partial_trading => {
                dst_open       => '-1h',
                dst_close      => '3h10m',
                standard_open  => '0s',
                standard_close => '4h10m',
            },
            dst => {
                daily_close      => '5h',
                daily_open       => '-1h',
                daily_settlement => '8h',
            },
        },
        date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol           => 'SES',
        trading_timezone => 'Asia/Singapore',
        market_times     => {
            standard => {
                daily_close      => '9h',
                daily_open       => '1h',
                daily_settlement => '12h',
            },
            partial_trading => {
                standard_open  => '1h',
                standard_close => '4h30m',
            },
        },
        date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol           => 'TSE',
        trading_timezone => 'Asia/Tokyo',
        market_times     => {
            standard => {
                afetrnoon_open   => '3h30m',
                daily_close      => '6h',
                daily_open       => '0s',
                morning_close    => '2h30m',
                daily_settlement => '9h'
            },
        },
        date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $recorded_date,
        date          => Date::Utility->new,
    }) for (qw/GBP JPY USD AUD EUR/);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $recorded_date,
    }) for qw(frxUSDJPY frxGBPJPY frxGBPUSD);

my $bet_params = {
    bet_type     => 'CALL',
    date_pricing => $date_pricing,
    date_start   => $date_start,
    date_expiry  => $date_expiry,
    underlying   => $symbol,
    barrier      => $barrier,
    payout       => $payout,
    currency     => $currency,
};

my $bet;
lives_ok { $bet = produce_contract($bet_params); } 'Can create example CALL bet';
is($bet->volsurface->recorded_date->datetime_iso8601, '2012-11-08T00:00:00Z',                           'We loaded the correct volsurface');
is($bet->volsurface->cutoff->code,                    'UTC 23:59',                                      'Cutoff is correct for 8-Nov');
is($bet->pricing_engine_name,                         'BOM::Product::Pricing::Engine::Intraday::Forex', 'Bet selected IH pricing engine.');
my $ask = $bet->ask_probability;
is(roundnear(1e-4, $ask->amount),                             0.4965, 'Ask probability is correct.');
is(roundnear(1e-2, $bet->average_tick_count),                 7.43,   'Correct number of average ticks.');
is(roundnear(1e-4, $ask->peek_amount('model_markup')),        0.0131, 'model_markup is correct.');
is(roundnear(1e-4, $ask->peek_amount('intraday_bounceback')), 0.0063, 'intraday_bounceback is correct.');
is(roundnear(1e-4, $ask->peek_amount('vega_correction')),     0.0018, 'vega_correction is correct.');
is($ask->peek_amount('path_dependent_markup'), undef, 'No path dependent markup.');

$bet_params = {
    bet_type     => 'PUT',
    date_pricing => $date_pricing,
    date_start   => $date_start,
    date_expiry  => $date_expiry,
    underlying   => $symbol,
    barrier      => $barrier,
    payout       => $payout,
    currency     => $currency,
};

lives_ok { $bet = produce_contract($bet_params); } 'Can create example PUT bet';
is($bet->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'Bet selected IH pricing engine.');
$ask = $bet->ask_probability;
is(roundnear(1e-4, $ask->amount),                             0.5297,  'Ask probability is correct.');
is(roundnear(1e-2, $bet->average_tick_count),                 7.43,    'Correct number of average ticks.');
is(roundnear(1e-4, $ask->peek_amount('model_markup')),        0.0131,  'model_markup is correct.');
is(roundnear(1e-4, $ask->peek_amount('intraday_bounceback')), -0.0063, 'intraday_bounceback is correct.');
is(roundnear(1e-4, $ask->peek_amount('vega_correction')),     -0.0018, 'vega_correction is correct.');
is($ask->peek_amount('path_dependent_markup'), undef, 'No path dependent markup.');

SKIP: {
    skip("There aren't any underlyings with EXPIRYMISS/EXPIRYRANGE enabled currently, although the engine should be able to support it.", 1);
    $bet_params = {
        bet_type     => 'EXPIRYMISS',
        date_pricing => $date_pricing,
        date_start   => $date_start,
        date_expiry  => $date_expiry,
        underlying   => $symbol,
        barrier      => $barrier,
        barrier2     => $barrier_low,
        payout       => $payout,
        currency     => $currency,
    };

    lives_ok { $bet = produce_contract($bet_params); } 'Can create example EXPIRYMISS bet';
    is($bet->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'Bet selected IH pricing engine.');
    $ask = $bet->ask_probability;
    is(roundnear(1e-4, $ask->amount),                      1,      'Ask probability is correct.');
    is(roundnear(1e-2, $bet->average_tick_count),          7.48,   'Correct number of average ticks.');
    is(roundnear(1e-4, $ask->peek_amount('model_markup')), 0.0131, 'model_markup is correct.');
# Cannot check adjustments on composed bets.
    is($ask->peek_amount('path_dependent_markup'), undef, 'No path dependent markup.');

    $bet_params = {
        bet_type     => 'EXPIRYRANGE',
        date_pricing => $date_pricing,
        date_start   => $date_start,
        date_expiry  => $date_expiry,
        underlying   => $symbol,
        barrier      => $barrier,
        barrier2     => $barrier_low,
        payout       => $payout,
        currency     => $currency,
    };

    lives_ok { $bet = produce_contract($bet_params); } 'Can create example EXPIRYRANGE bet';
    is($bet->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'Bet selected IH pricing engine.');
    $ask = $bet->ask_probability;
    is(roundnear(1e-4, $ask->amount),                      0.0381, 'Ask probability is correct.');
    is(roundnear(1e-2, $bet->average_tick_count),          7.48,   'Correct number of average ticks.');
    is(roundnear(1e-4, $ask->peek_amount('model_markup')), 0.0131, 'model_markup is correct.');
# Cannot check adjustments on composed bets.
    is($ask->peek_amount('path_dependent_markup'), undef, 'No path dependent markup.');
}

$bet_params = {
    bet_type     => 'ONETOUCH',
    date_pricing => $date_pricing,
    date_start   => $date_start,
    date_expiry  => $date_start + 3600,
    underlying   => $symbol,
    barrier      => $barrier,
    payout       => $payout,
    currency     => $currency,
};

lives_ok { $bet = produce_contract($bet_params); } 'Can create example ONETOUCH bet';
is($bet->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'Bet selected IH pricing engine.');
$ask = $bet->ask_probability;
is(roundnear(1e-4, $ask->amount),                             1,      'Ask probability is correct.');
is(roundnear(1e-2, $bet->average_tick_count),                 6.17,   'Correct number of average ticks.');
is(roundnear(1e-4, $ask->peek_amount('model_markup')),        0.0303, 'model_markup is correct.');
is(roundnear(1e-4, $ask->peek_amount('intraday_bounceback')), 0.0095, 'intraday_bounceback is correct.');
is(roundnear(1e-4, $ask->peek_amount('vega_correction')),     0.0033, 'vega_correction is correct.');
is($ask->peek_amount('path_dependent_markup'), 2, 'Includes path dependent markup.');

$bet_params = {
    bet_type     => 'NOTOUCH',
    date_pricing => $date_pricing,
    date_start   => $date_start,
    date_expiry  => $date_start + 3600,
    underlying   => $symbol,
    barrier      => $barrier,
    payout       => $payout,
    currency     => $currency,
};

lives_ok { $bet = produce_contract($bet_params); } 'Can create example NOTOUCH bet';
is($bet->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'Bet selected IH pricing engine.');
$ask = $bet->ask_probability;
is(roundnear(1e-4, $ask->amount),                             0.0504,  'Ask probability is correct.');
is(roundnear(1e-2, $bet->average_tick_count),                 6.17,    'Correct number of average ticks.');
is(roundnear(1e-4, $ask->peek_amount('model_markup')),        0.0303,  'model_markup is correct.');
is(roundnear(1e-4, $ask->peek_amount('intraday_bounceback')), -0.0095, 'intraday_bounceback is correct.');
is(roundnear(1e-4, $ask->peek_amount('vega_correction')),     -0.0033, 'vega_correction is correct.');
is($ask->peek_amount('path_dependent_markup'), 2, 'Includes path dependent markup.');

$bet_params = {
    bet_type     => 'CALL',
    date_pricing => $date_pricing + 60,
    date_start   => $date_start,
    date_expiry  => $date_expiry,
    underlying   => $symbol,
    barrier      => $barrier,
    payout       => $payout,
    currency     => $currency,
};

lives_ok { $bet = produce_contract($bet_params); } 'The CALL a minute later.';
is($bet->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'Bet selected IH pricing engine.');
$ask = $bet->ask_probability;
is(roundnear(1e-4, $ask->amount),                             0.4805, 'Ask probability is correct.');
is(roundnear(1e-2, $bet->average_tick_count),                 7.51,   'Correct number of average ticks.');
is(roundnear(1e-4, $ask->peek_amount('model_markup')),        0.0131, 'model_markup is correct.');
is(roundnear(1e-4, $ask->peek_amount('intraday_bounceback')), 0.0059, 'intraday_bounceback is correct.');
is(roundnear(1e-4, $ask->peek_amount('vega_correction')),     0.0029, 'vega_correction is correct.');
is($ask->peek_amount('path_dependent_markup'), undef, 'No path dependent markup.');
is(roundnear(1e-4, $bet->pricing_args->{iv}), 0.1105, 'Expected intraday vol amount');

my $forced_iv = 1.2180;    # Make it 10x higher and see what happens.
$bet_params->{pricing_vol} = $forced_iv;
lives_ok { $bet = produce_contract($bet_params); } 'The CALL a minute later with a forced vol';
is($bet->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'Bet selected IH pricing engine.');
$ask = $bet->ask_probability;
is(roundnear(1e-4, $ask->amount), 0.5085, 'Ask probability is correct.');
is($bet->average_tick_count, undef, 'Average tick count is undefined since we never computed vol');
is(roundnear(1e-4, $ask->peek_amount('model_markup')),        0.013,  'model_markup is correct.');
is(roundnear(1e-4, $ask->peek_amount('intraday_bounceback')), 0.0005, 'intraday_bounceback is correct.');
is(roundnear(1e-4, $ask->peek_amount('vega_correction')),     0.0000, 'vega_correction is correct.');
is($ask->peek_amount('path_dependent_markup'), undef, 'No path dependent markup.');
is(roundnear(1e-4, $bet->pricing_args->{iv}), 1.2180, 'Used our forced vol amount');

1;
