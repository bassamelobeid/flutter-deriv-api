use strict;
use warnings;

use Data::Decimate qw(decimate);
use Date::Utility;
use File::Spec;
use Test::Most tests => 2;
use Test::Warnings;
use Volatility::EconomicEvents;
use YAML::XS qw(LoadFile);
use LandingCompany::Registry;
use Date::Utility;
use Test::MockModule;

use BOM::Market::DataDecimate;
use BOM::MarketData qw(create_underlying_db create_underlying);
use BOM::MarketData::Types;
use BOM::Config::Chronicle;
use BOM::Config::Redis;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Config::Runtime;
use Test::BOM::UnitTestPrice;

my $now = Date::Utility->new(1505957400);

my $payout = 100;

my $offerings_cfg = BOM::Config::Runtime->instance->get_offerings_config;

Test::BOM::UnitTestPrice::create_pricing_data('frxEURUSD', 'USD', $now);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(USD EUR EUR-USD USD-JPY);

my $forex = create_underlying('frxEURUSD', $now);

Quant::Framework::Utils::Test::create_doc(
    'volsurface_delta',
    {
        underlying       => $forex,
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader,
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer,
        recorded_date    => $now,
        surface_data     => {
            '273' => {
                'vol_spread' => {
                    '50' => '0.00199999999999999',
                    '75' => '0.00285714285714285',
                    '25' => '0.00285714285714285'
                },
                'tenor' => '9M',
                'smile' => {
                    '50' => '0.07955',
                    '75' => '0.0821',
                    '25' => '0.0831'
                }
            },
            '14' => {
                'tenor' => '2W',
                'smile' => {
                    '25' => '0.0829125',
                    '75' => '0.0797875',
                    '50' => '0.080325'
                },
                'vol_spread' => {
                    '75' => '0.00707142857142856',
                    '50' => '0.00494999999999999',
                    '25' => '0.00707142857142856'
                }
            },
            '365' => {
                'vol_spread' => {
                    '50' => '0.00200000000000001',
                    '75' => '0.00285714285714287',
                    '25' => '0.00285714285714287'
                },
                'tenor' => '1Y',
                'smile' => {
                    '25' => '0.083325',
                    '75' => '0.082775',
                    '50' => '0.07985'
                }
            },
            '63' => {
                'tenor' => '2M',
                'smile' => {
                    '50' => '0.0789',
                    '75' => '0.07915',
                    '25' => '0.08235'
                },
                'vol_spread' => {
                    '75' => '0.00285714285714286',
                    '50' => '0.002',
                    '25' => '0.00285714285714286'
                }
            },
            '182' => {
                'smile' => {
                    '75' => '0.079925',
                    '50' => '0.0785',
                    '25' => '0.082275'
                },
                'tenor'      => '6M',
                'vol_spread' => {
                    '25' => '0.00285714285714286',
                    '75' => '0.00285714285714286',
                    '50' => '0.002'
                }
            },
            '21' => {
                'smile' => {
                    '75' => '0.078125',
                    '50' => '0.077925',
                    '25' => '0.081075'
                },
                'tenor'      => '3W',
                'vol_spread' => {
                    '25' => '0.00550000000000001',
                    '50' => '0.00385000000000001',
                    '75' => '0.00550000000000001'
                }
            },
            '32' => {
                'tenor' => '1M',
                'smile' => {
                    '25' => '0.078525',
                    '50' => '0.075175',
                    '75' => '0.075575'
                },
                'vol_spread' => {
                    '50' => '0.00215',
                    '75' => '0.00307142857142857',
                    '25' => '0.00307142857142857'
                }
            },
            '7' => {
                'vol_spread' => {
                    '25' => '0.0149285714285714',
                    '75' => '0.0149285714285714',
                    '50' => '0.01045'
                },
                'smile' => {
                    '50' => '0.083675',
                    '75' => '0.083975',
                    '25' => '0.086525'
                },
                'tenor' => '1W'
            },
            '91' => {
                'smile' => {
                    '50' => '0.080975',
                    '75' => '0.08145',
                    '25' => '0.0846'
                },
                'tenor'      => '3M',
                'vol_spread' => {
                    '25' => '0.00278571428571429',
                    '75' => '0.00278571428571429',
                    '50' => '0.00195'
                }
            },
            '1' => {
                'vol_spread' => {
                    '75' => '0.0482142857142857',
                    '50' => '0.03375',
                    '25' => '0.0482142857142857'
                },
                'smile' => {
                    '75' => '0.1193875',
                    '50' => '0.118625',
                    '25' => '0.1204625'
                },
                'expiry_date' => '22-Sep-17',
                'tenor'       => 'ON'
            }
        },

        'creation_date' => Date::Utility->new(1505954767)});

BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([1.1875, $now->epoch, 'frxEURUSD']);

my $mocked_c = Test::MockModule->new('BOM::Product::Contract');
$mocked_c->mock('discount_rate', sub { return 0.0117593275570776; });
$mocked_c->mock('mu',            sub { return 0.0174986768721461; });

subtest 'barrier too close and too far to spot' => sub {
    foreach my $contract_type (qw(CALLSPREAD)) {

        #{
        #  'high' => '1.1875',
        #  'low' => '1.1875'
        #};
        $mocked_c->mock(
            'spot_min_max',
            sub {
                return {
                    'high' => '1.18752',
                    'low'  => '1.18742'
                };
            });

        my $duration = 180;
        lives_ok {
            my $c = produce_contract({
                bet_type     => $contract_type,
                underlying   => $forex,
                date_start   => $now,
                date_pricing => $now,
                duration     => $duration . 's',
                currency     => 'USD',
                payout       => $payout,
                high_barrier => 'S1P',
                low_barrier  => 'S-1P',
            });
            isa_ok $c->pricing_engine, 'Pricing::Engine::Callputspread';
            is $c->ask_price, 50.97, 'ask price for high => 1.18752, low => 1.18742';
        }
        'survived';

        #{
        #  'low' => '1.18701',
        #  'high' => '1.18833'
        #};
        $mocked_c->mock(
            'spot_min_max',
            sub {
                return {
                    'low'  => '1.18701',
                    'high' => '1.18833'
                };
            });
        $duration = 7200;
        lives_ok {
            my $c = produce_contract({
                bet_type     => $contract_type,
                underlying   => $forex,
                date_start   => $now,
                date_pricing => $now,
                duration     => $duration . 's',
                currency     => 'USD',
                payout       => $payout,
                high_barrier => 'S1P',
                low_barrier  => 'S-1P',
            });
            isa_ok $c->pricing_engine, 'Pricing::Engine::Callputspread';
            is $c->ask_price, 53.62, 'ask price for low => 1.18701, high => 1.18833';
        }
        'survived';

        $mocked_c->mock(
            'spot_min_max',
            sub {
                return {
                    'high' => '1.18752',
                    'low'  => '1.18742'
                };
            });
        $duration = 180;
        lives_ok {
            my $c = produce_contract({
                bet_type     => $contract_type,
                underlying   => $forex,
                date_start   => $now,
                date_pricing => $now,
                duration     => $duration . 's',
                currency     => 'USD',
                payout       => $payout,
                high_barrier => 'S400P',
                low_barrier  => 'S-400P',
            });
            isa_ok $c->pricing_engine, 'Pricing::Engine::Callputspread';
            is $c->ask_price, 50.95, 'ask price for high => 1.18752, low => 1.18742';
        }
        'survived';

        $mocked_c->mock(
            'spot_min_max',
            sub {
                return {
                    'low'  => '1.18701',
                    'high' => '1.18833'
                };
            });
        $duration = 7200;
        lives_ok {
            my $c = produce_contract({
                bet_type     => $contract_type,
                underlying   => $forex,
                date_start   => $now,
                date_pricing => $now,
                duration     => $duration . 's',
                currency     => 'USD',
                payout       => $payout,
                high_barrier => 'S400P',
                low_barrier  => 'S-400P',
            });
            isa_ok $c->pricing_engine, 'Pricing::Engine::Callputspread';
            is $c->ask_price, 53.84, 'ask price for low => 1.18701, high => 1.18833';
        }
        'survived';

    }

    }
