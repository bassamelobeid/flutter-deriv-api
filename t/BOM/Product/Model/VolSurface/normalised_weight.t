#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Warnings qw/warning/;
use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData;
use BOM::Config::Chronicle;
use Date::Utility;
use BOM::MarketData qw(create_underlying);
use BOM::Product::ContractFactory qw(produce_contract);

initialize_realtime_ticks_db();
use Quant::Framework::VolSurface::Delta;

my $now = Date::Utility->new('2020-09-21 00:00:01');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'holiday',
    {
        recorded_date => $now,
        calendar      => {
            "2020-09-21" => {
                "Bank Holiday" => ['JPY'],
            },
        }});

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxEURJPY',
        recorded_date => $now->minus_time_interval('10m'),
        surface       => {
            '14' => {
                'vol_spread' => {
                    '25' => '0.00999999999999999',
                    '50' => '0.00699999999999999',
                    '75' => '0.00999999999999999'
                },
                'smile' => {
                    '75' => '0.0825',
                    '50' => '0.07875',
                    '25' => '0.0778'
                },
                'tenor' => '2W'
            },
            '365' => {
                'smile' => {
                    '25' => '0.089825',
                    '50' => '0.0931',
                    '75' => '0.103875'
                },
                'tenor'      => '1Y',
                'vol_spread' => {
                    '25' => '0.0042857142857143',
                    '75' => '0.0042857142857143',
                    '50' => '0.00300000000000001'
                }
            },
            '87' => {
                'smile' => {
                    '50' => '0.08585',
                    '75' => '0.0922875',
                    '25' => '0.0835125'
                },
                'tenor'      => '3M',
                'vol_spread' => {
                    '50' => '0.00380000000000001',
                    '75' => '0.00542857142857144',
                    '25' => '0.00542857142857144'
                }
            },
            '21' => {
                'tenor' => '3W',
                'smile' => {
                    '25' => '0.0806375',
                    '75' => '0.0859625',
                    '50' => '0.081875'
                },
                'vol_spread' => {
                    '25' => '0.00707142857142859',
                    '50' => '0.00495000000000001',
                    '75' => '0.00707142857142859'
                }
            },
            '7' => {
                'vol_spread' => {
                    '50' => '0.00949999999999999',
                    '75' => '0.0135714285714286',
                    '25' => '0.0135714285714286'
                },
                'smile' => {
                    '25' => '0.0767125',
                    '75' => '0.0811375',
                    '50' => '0.0777'
                },
                'tenor' => '1W'
            },
            '58' => {
                'tenor' => '2M',
                'smile' => {
                    '25' => '0.0821375',
                    '50' => '0.084025',
                    '75' => '0.0894125'
                },
                'vol_spread' => {
                    '50' => '0.00365',
                    '75' => '0.00521428571428572',
                    '25' => '0.00521428571428572'
                }
            },
            '28' => {
                'vol_spread' => {
                    '25' => '0.00492857142857143',
                    '75' => '0.00492857142857143',
                    '50' => '0.00345'
                },
                'tenor' => '1M',
                'smile' => {
                    '50' => '0.081225',
                    '75' => '0.0857625',
                    '25' => '0.0797375'
                }
            },
            '273' => {
                'tenor' => '9M',
                'smile' => {
                    '50' => '0.09205',
                    '75' => '0.1017875',
                    '25' => '0.0890125'
                },
                'vol_spread' => {
                    '50' => '0.0032',
                    '75' => '0.00457142857142858',
                    '25' => '0.00457142857142858'
                }
            },
            '179' => {
                'smile' => {
                    '25' => '0.0868',
                    '50' => '0.089875',
                    '75' => '0.0985'
                },
                'tenor'      => '6M',
                'vol_spread' => {
                    '25' => '0.00492857142857144',
                    '50' => '0.00345000000000001',
                    '75' => '0.00492857142857144'
                }
            },
            '1' => {
                'vol_spread' => {
                    '25' => '0.0428571428571429',
                    '75' => '0.0428571428571429',
                    '50' => '0.03'
                },
                'tenor' => 'ON',
                'smile' => {
                    '25' => '0.07775',
                    '75' => '0.08215',
                    '50' => '0.07855'
                }
            },
        }}

);

my @ticks_to_add =
    ([$now->epoch => 100], [$now->epoch + 1 => 100], [$now->epoch + 2 => 100.020], [$now->epoch + 30 => 100.030], [$now->epoch + 3600 => 100.020]);

my $close_tick;

foreach my $pair (@ticks_to_add) {

    $close_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxEURJPY',
        epoch      => $pair->[0],
        quote      => $pair->[1],
    });
}

my $args = {
    bet_type     => 'ONETOUCH',
    underlying   => 'frxEURJPY',
    date_start   => $now,
    date_pricing => $now,
    date_expiry  => Date::Utility->new('2020-09-27 00:05:00'),
    currency     => 'USD',
    payout       => 10,
    barrier      => '150',
};

subtest 'Holiday weight issue' => sub {

    my $c = produce_contract($args);
    ok $c->pricing_vol, 'Weights are calculated correctly during bank holiday';
};

done_testing;
