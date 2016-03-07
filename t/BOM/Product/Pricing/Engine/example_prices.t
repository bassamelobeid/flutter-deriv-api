use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use Test::Most 0.22 (tests => 165);
use Test::NoWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use Date::Utility;
use Format::Util::Numbers qw( roundnear );
use BOM::Product::ContractFactory qw( produce_contract );

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;

use BOM::Market::Underlying;
use Path::Tiny;
use YAML::XS qw(LoadFile);

my $data_file       = path(__FILE__)->parent->child('config.yml');
my $config_data     = LoadFile($data_file);
my $volsurface      = $config_data->{volsurface};
my $interest_rate   = $config_data->{currency};
my $dividend        = $config_data->{index};
my $expected_result = $config_data->{expected_result};

my $date_start   = 1398152636;
my $date_pricing = $date_start;

my $recorded_date = Date::Utility->new($date_start);
# This test are benchmarked againsts market rates.
# The intermittent failure of the test is due to the switching between implied and market rates in app settings.
my $mocked = Test::MockModule->new('BOM::Market::Underlying');
$mocked->mock('uses_implied_rate', sub { return 0 });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'holiday',
    {
        recorded_date => $recorded_date,
        calendar      => {
            '2014-04-18' => {
                'Good Friday' => ['EUR', 'GBP', 'USD', 'FSE', 'LSE'],
            },
            '2014-04-21' => {
                'Easter Monday' => ['EUR', 'GBP', 'FSE', 'LSE'],
            },
            '2014-04-29' => {
                "Showa Day" => ['JPY'],
            },
            '2014-05-01' => {
                'Labour Day' => ['EUR', 'FSE'],
            },
            '2014-05-05' => {
                "Children's Day"         => ['JPY'],
                "Early May Bank Holiday" => ['GBP', 'LSE'],
            },
            '2014-05-06' => {
                'Greenery Day' => ['JPY'],
            },
            '2014-05-26' => {
                'Late May Bank Holiday' => ['GBP', 'LSE'],
                'Memorial Day'          => ['USD'],
            },
            '2014-07-04' => {
                "Independence Day" => ['USD'],
            },
            '2014-07-21' => {
                'Marine Day' => ['JPY'],
            },
            '2014-08-25' => {
                'Summer Bank Holiday' => ['GBP', 'LSE'],
            },
            '2014-09-01' => {
                "Labor Day" => ['USD'],
            },
            '2014-09-15' => {
                'Respect for the aged Day' => ['JPY'],
            },
            '2014-09-23' => {
                'Autumnal Equinox Day' => ['JPY'],
            },
            '2014-10-03' => {
                'Day Of German Unity' => ['FSE'],
            },
            '2014-10-13' => {
                'Health Sport Day' => ['JPY'],
                'Columbus Day'     => ['USD'],
            },
            '2014-11-03' => {
                'Culture Day' => ['JPY'],
            },
            '2014-11-11' => {
                "Veterans' Day" => ['USD'],
            },
            '2014-11-24' => {
                'Labor Thanksgiving' => ['JPY'],
            },
            '2014-11-27' => {
                "Thanksgiving Day" => ['USD'],
            },
            '2014-12-23' => {
                "Emperor's Birthday" => ['JPY'],
            },
            '2014-12-24' => {
                'pseudo-holiday' => ['JPY', 'EUR', 'GBP', 'USD'],
                'Christmas Eve'  => ['FSE'],
            },
            '2014-12-25' => {
                'Christmas Day' => ['USD', 'EUR', 'GBP', 'FSE', 'LSE', 'FOREX', 'SAS'],
            },
            '2014-12-26' => {
                'Christmas Day'     => ['EUR'],
                'Christmas Holiday' => ['FSE'],
                'Boxing Day'        => ['GBP', 'LSE'],
            },
            '2014-12-31' => {
                "New Year's eve" => ['JPY', 'FSE'],
                "pseudo-holiday" => ['EUR', 'GBP', 'USD'],
            },
            '2015-01-01' => {
                "New Year's Day" => ['FSE', 'LSE'],
            },
            '2015-04-03' => {
                'Good Friday' => ['FSE', 'LSE'],
            },
            '2015-04-06' => {
                'Easter Monday' => ['FSE', 'LSE'],
            },
        },
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol        => $_,
        rates         => $interest_rate->{$_}->{rates},
        recorded_date => Date::Utility->new($date_pricing),
    }) for qw( GBP JPY USD EUR JPY-USD EUR-USD GBP-USD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
    }) for qw( SAR SAR-USD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $recorded_date,
        surface       => $volsurface->{$_}{surfaces},
    }) for qw(frxUSDJPY frxEURUSD frxGBPUSD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => $_,
        recorded_date => $recorded_date,
        surface       => $volsurface->{$_}{surfaces},
    }) for qw(FTSE GDAXI);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => $_,
        date          => Date::Utility->new,
        recorded_date => $recorded_date,
        rates         => $dividend->{$_}{rates},
    }) for qw( FTSE GDAXI);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'SASEIDX',
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('correlation_matrix', {recorded_date => $recorded_date});

foreach my $underlying ('frxUSDJPY', 'frxEURUSD', 'FTSE', 'GDAXI') {
    foreach my $bet_type ('CALL', 'NOTOUCH', 'RANGE', 'EXPIRYRANGE', 'DIGITMATCH') {
        my $expectations = $expected_result->{$underlying}->{$bet_type};
        next unless scalar keys %$expectations;

        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => $underlying,
            epoch      => $date_pricing,
            quote      => $expectations->{spot},
        });

        my %barriers =
            $expectations->{barrier2}
            ? (
            high_barrier => $expectations->{barrier},
            low_barrier  => $expectations->{barrier2})
            : (barrier => $expectations->{barrier});
        my $bet_params = {
            bet_type     => $bet_type,
            date_pricing => $date_pricing,
            date_start   => $date_start,
            duration     => $expectations->{duration},
            underlying   => $underlying,
            payout       => 100,
            currency     => 'USD',
            %barriers,
        };
        my $bet;
        lives_ok { $bet = produce_contract($bet_params); } "Can create example $bet_type bet on $underlying";
        is($bet->volsurface->recorded_date->datetime_iso8601, '2014-04-22T07:43:56Z',        'We loaded the correct volsurface');
        is($bet->pricing_engine_name,                         $expectations->{price_engine}, 'Contract selected ' . $expectations->{price_engine});

        if ($bet->two_barriers) {
            is($bet->high_barrier->supplied_barrier, $expectations->{barrier}, 'Barrier is set as expected.');
            is($bet->low_barrier->supplied_barrier, $expectations->{barrier2}, ' .. and so is barrier2.') if (defined $expectations->{barrier2});
        } else {
            is($bet->barrier->supplied_barrier, $expectations->{barrier}, 'Barrier is set as expected.');
        }
        my $ask = $bet->ask_probability;
        is(roundnear(1e-4, $ask->amount), $expectations->{ask_prob}, 'Ask probability is correct.');
        my $theo = $bet->theo_probability;
        is(roundnear(1e-4, $theo->amount),                          $expectations->{theo_prob},         'Theo probability is correct.');
        is(roundnear(1e-4, $ask->peek_amount('total_markup')),      $expectations->{total_markup},      'Total markup is correct.');
        is(roundnear(1e-4, $ask->peek_amount('commission_markup')), $expectations->{commission_markup}, 'Commission markup is correct.');
        is(roundnear(1e-4, $ask->peek_amount('risk_markup')),       $expectations->{risk_markup},       'Risk markup is correct.');
        $date_pricing++;
        $date_start++;
    }
}

my $middle_east_intraday = produce_contract('CALL_SASEIDX_10_1447921800F_1447929000_S0P_0', 'USD');
my $middle_east_intraday_ask = $middle_east_intraday->ask_probability;
is(roundnear(1e-4, $middle_east_intraday_ask->peek_amount('commission_markup')), 0.05, 'Commission markup for middle east is 5%');

my $middle_east_daily = produce_contract('CALL_SASEIDX_10_1447921800_1448022600F_S0P_0', 'USD');
my $middle_east_daily_ask = $middle_east_daily->ask_probability;
is(roundnear(1e-4, $middle_east_daily_ask->peek_amount('commission_markup')), 0.05, 'Commission markup for middle east is 5%');

my $GDAXI_intraday = produce_contract('CALL_GDAXI_10_1448013600F_1448020800_S0P_0', 'USD');
my $GDAXI_intraday_ask = $GDAXI_intraday->ask_probability;
is(roundnear(1e-4, $GDAXI_intraday_ask->peek_amount('commission_markup')), 0.03, 'Commission markup for indices is 3%');

1;
