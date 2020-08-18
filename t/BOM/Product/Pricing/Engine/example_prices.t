use strict;
use warnings;

# The cache causes our prices to vary slightly, so we disable for all QF modules.
BEGIN { $ENV{QUANT_FRAMEWORK_CACHE} = 0 }

use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use Test::Most 0.22 (tests => 129);
use Test::Warnings;
use Test::MockModule;
use File::Spec;
use Date::Utility;
use Path::Tiny;
use YAML::XS qw(LoadFile);
use Test::MockModule;
use Format::Util::Numbers qw/roundcommon/;

use Postgres::FeedDB::Spot::Tick;

use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

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
my $u_c = Test::MockModule->new('Quant::Framework::Underlying');
$u_c->mock('uses_implied_rate', sub { return 0 });

#create an empty un-used even so ask_price won't fail preparing market data for pricing engine
#Because the code to prepare market data is called for all pricings in Contract
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                event_name   => 'FOMC',
            }]});

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
                'Christmas Day' => ['USD', 'EUR', 'GBP', 'FSE', 'LSE', 'FOREX', 'SAS', 'METAL'],
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
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
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
    }) for qw( AED AED-USD);

for my $d ($recorded_date, Date::Utility->new('19-Nov-2015')) {
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $d,
            surface       => $volsurface->{$_}{surfaces},
        }) for qw(frxUSDJPY frxEURUSD frxGBPUSD);
}
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => $_,
        recorded_date => $recorded_date,
        surface       => $volsurface->{$_}{surfaces},
    }) for qw(OTC_FCHI OTC_GDAXI);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => $_,
        date          => Date::Utility->new,
        recorded_date => $recorded_date,
        rates         => $dividend->{$_}{rates},
    }) for qw( OTC_FCHI OTC_GDAXI);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'correlation_matrix',
    {
        recorded_date => $recorded_date,
        correlations  => {
            OTC_FCHI => {
                GBP => {
                    '3M'  => 0.356,
                    '6M'  => 0.336,
                    '9M'  => 0.32,
                    '12M' => 0.307,
                },
                USD => {
                    '3M'  => 0.554,
                    '6M'  => 0.538,
                    '9M'  => 0.525,
                    '12M' => 0.516,
                },
            },
            OTC_GDAXI => {
                USD => {
                    '3M'  => 0.506,
                    '6M'  => 0.49,
                    '9M'  => 0.477,
                    '12M' => 0.467,
                }
            },
            OTC_FCHI => {
                GBP => {
                    '3M'  => 0.356,
                    '6M'  => 0.336,
                    '9M'  => 0.32,
                    '12M' => 0.307,
                },
                USD => {
                    '3M'  => 0.554,
                    '6M'  => 0.538,
                    '9M'  => 0.525,
                    '12M' => 0.516,
                },
            },
        },
    });

foreach my $underlying ('frxUSDJPY', 'frxEURUSD', 'OTC_FCHI', 'OTC_GDAXI') {
    foreach my $bet_type ('CALL', 'NOTOUCH', 'RANGE', 'EXPIRYRANGE', 'DIGITMATCH') {
        my $expectations = $expected_result->{$underlying}->{$bet_type};
        next unless scalar keys %$expectations;

        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => $underlying,
            epoch      => $date_pricing,
            quote      => $expectations->{spot},
        });

        my $mock = Test::MockModule->new('Quant::Framework::Underlying');
        $mock->mock('spot_tick', sub { Postgres::FeedDB::Spot::Tick->new({epoch => $date_pricing, quote => $expectations->{spot}}); });

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
        is($bet->volsurface->creation_date->datetime_iso8601, '2014-04-22T07:43:56Z',        'We loaded the correct volsurface');
        is($bet->pricing_engine_name,                         $expectations->{price_engine}, 'Contract selected ' . $expectations->{price_engine});

        if ($bet->two_barriers) {
            is($bet->high_barrier->supplied_barrier, $expectations->{barrier},  'Barrier is set as expected.');
            is($bet->low_barrier->supplied_barrier,  $expectations->{barrier2}, ' .. and so is barrier2.') if (defined $expectations->{barrier2});
        } else {
            is($bet->barrier->supplied_barrier, $expectations->{barrier}, 'Barrier is set as expected.');
        }
        my $theo = $bet->theo_probability;
        is(
            roundcommon(1e-4, $theo->amount),
            roundcommon(1e-4, $expectations->{theo_prob}),
            'Theo probability is correct for ' . $bet->pricing_engine_name
        );
        cmp_ok(roundcommon(1e-4, $bet->commission_markup->amount), '==', $expectations->{commission_markup}, 'Commission markup is correct.');
        is(
            roundcommon(1e-4, $bet->risk_markup->amount),
            roundcommon(1e-4, $expectations->{risk_markup}),
            'Risk markup is correctfor ' . $bet->pricing_engine_name
        );
        $date_pricing++;
        $date_start++;

        $mock->unmock('spot_tick');
    }
}

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol       => 'frxUSDAED',
        surface_data => {
            1 => {
                vol_spread => {50 => 0},
                smile      => {
                    25 => 0.1,
                    50 => 0.1,
                    75 => 0.1
                }
            },
            7 => {
                vol_spread => {50 => 0},
                smile      => {
                    25 => 0.1,
                    50 => 0.1,
                    75 => 0.1
                }
            },
        },
        recorded_date => Date::Utility->new('19-Nov-2015'),
    });

my $GDAXI_intraday     = produce_contract('CALL_OTC_GDAXI_10_1448013600F_1448020800_S0P_0', 'USD');
my $GDAXI_intraday_ask = $GDAXI_intraday->ask_probability;
cmp_ok(roundcommon(1e-4, $GDAXI_intraday->commission_markup->amount), '==', 0.025, 'Commission markup for indices is 3%');

1;
