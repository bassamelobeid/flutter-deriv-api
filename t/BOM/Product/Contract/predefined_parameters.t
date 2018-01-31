#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warnings;
use Test::MockModule;
use Test::Warn;

use Cache::RedisDB;
use List::Util qw(first);
use Date::Utility;
use Encode;
use JSON::MaybeXS;

use BOM::MarketData qw(create_underlying);
use BOM::Product::ContractFinder;
use BOM::Product::Contract::PredefinedParameters qw(update_predefined_highlow get_expired_barriers);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Postgres::FeedDB::Spot::Tick;

my $supported_symbol = 'frxUSDJPY';
my $monday           = Date::Utility->new('2016-11-14');    # monday

subtest 'non trading day' => sub {
    my $saturday = Date::Utility->new('2016-11-19');        # saturday
    BOM::Test::Data::Utility::UnitTestMarketData::create_trading_periods($supported_symbol, $saturday);
    my $offerings = BOM::Product::ContractFinder->new(for_date => $saturday)->multi_barrier_contracts_for({
            symbol => $supported_symbol,
        })->{available};
    ok !@$offerings, 'no offerings were generated on non trading day';
    setup_ticks($supported_symbol, [[$monday->minus_time_interval('400d')], [$monday]]);
    BOM::Test::Data::Utility::UnitTestMarketData::create_trading_periods($supported_symbol, $monday);
    $offerings = BOM::Product::ContractFinder->new(for_date => $monday)->multi_barrier_contracts_for({
            symbol => $supported_symbol,
            date   => $monday
        })->{available};
    ok @$offerings, 'generates predefined offerings on a trading day';
};

subtest 'intraday trading period' => sub {
    # 0 - underlying symbol
    # 1 - expected contract category
    # 2 - generation time
    # 3 - expected offerings count
    # 4 - expected trading periods (order matters)
    my @test_inputs = (
        # monday at 00:00GMT
        [
            'frxUSDJPY',
            'callput',
            '2016-11-14 00:00:00',
            4,
            [
                ['2016-11-14 00:00:00', '2016-11-14 02:00:00'],
                ['2016-11-14 00:00:00', '2016-11-14 06:00:00'],
                ['2016-11-14 00:00:00', '2016-11-14 02:00:00'],
                ['2016-11-14 00:00:00', '2016-11-14 06:00:00'],
            ]
        ],
        # monday at 00:59GMT
        [
            'frxUSDJPY',
            'callput',
            '2016-11-14 00:59:00',
            4,
            [
                ['2016-11-14 00:00:00', '2016-11-14 02:00:00'],
                ['2016-11-14 00:00:00', '2016-11-14 06:00:00'],
                ['2016-11-14 00:00:00', '2016-11-14 02:00:00'],
                ['2016-11-14 00:00:00', '2016-11-14 06:00:00'],
            ]
        ],
        # monday at 01:59GMT
        [
            'frxUSDJPY',
            'callput',
            '2016-11-14 01:59:00',
            4,
            [
                ['2016-11-14 00:00:00', '2016-11-14 02:00:00'],
                ['2016-11-14 00:00:00', '2016-11-14 06:00:00'],
                ['2016-11-14 00:00:00', '2016-11-14 02:00:00'],
                ['2016-11-14 00:00:00', '2016-11-14 06:00:00'],
            ]
        ],
        [
            'frxUSDJPY',
            'callput',
            '2016-11-14 05:59:00',
            4,
            [
                ['2016-11-14 04:00:00', '2016-11-14 06:00:00'],
                ['2016-11-14 00:00:00', '2016-11-14 06:00:00'],
                ['2016-11-14 04:00:00', '2016-11-14 06:00:00'],
                ['2016-11-14 00:00:00', '2016-11-14 06:00:00'],
            ]
        ],
        [
            'frxUSDJPY',
            'callput',
            '2016-11-14 17:59:00',
            4,
            [
                ['2016-11-14 16:00:00', '2016-11-14 18:00:00'],
                ['2016-11-14 12:00:00', '2016-11-14 18:00:00'],
                ['2016-11-14 16:00:00', '2016-11-14 18:00:00'],
                ['2016-11-14 12:00:00', '2016-11-14 18:00:00'],
            ]
        ],
        ['frxUSDJPY', 'callput', '2016-11-14 18:00:00', 0, []],
    );

    foreach my $input (@test_inputs) {
        my ($symbol, $category, $date, $count, $periods) = map { $input->[$_] } (0 .. 4);
        $date = Date::Utility->new($date);
        setup_ticks($symbol, [[$date->minus_time_interval('400d')], [$date]]);
        note('generating for ' . $symbol . '. Time set to ' . $date->day_as_string . ' at ' . $date->time);
        BOM::Test::Data::Utility::UnitTestMarketData::create_trading_periods($symbol, $date);
        my $offerings = BOM::Product::ContractFinder->new(for_date => $date)->multi_barrier_contracts_for({
                symbol => $symbol,
            })->{available};
        my @intraday = grep { $_->{expiry_type} eq 'intraday' } @$offerings;
        is scalar(@intraday), $count, 'expected ' . $count . ' offerings on intraday at 00:00GMT';

        if ($count == 0 and scalar(@intraday) == 0) {
            pass('no intraday offerings found for ' . $symbol);
        } else {
            for (0 .. $#intraday) {
                my $got      = $intraday[$_];
                my $expected = $periods->[$_];
                like $got->{contract_category}, qr/$category/, 'valid contract category ' . $category;
                is $got->{trading_period}->{date_start}->{date},  $expected->[0], 'period starts at ' . $expected->[0];
                is $got->{trading_period}->{date_expiry}->{date}, $expected->[1], 'period ends at ' . $expected->[1];
            }
        }
    }
};

subtest 'predefined barriers' => sub {
    my $symbol = 'frxEURUSD';
    my $date   = Date::Utility->new("2015-08-24 00:00:00");
    setup_ticks($symbol, [[$date->minus_time_interval('400d')], [$date, 1.1521], [$date->plus_time_interval('10m'), 1.15591]]);
    my @inputs = ({
            match => {
                contract_category => 'callput',
                duration          => '2h',
                expiry_type       => 'intraday'
            },
            ticks => [[$date->minus_time_interval('400d')], [$date, 1.1521], [$date->plus_time_interval('10m'), 1.15591]],
            available_barriers => ['1.14940', '1.15000', '1.15060', '1.15138', '1.15210', '1.15282', '1.15360', '1.15420', '1.15480'],
            expired_barriers   => [],
        },
        {
            match => {
                contract_category => 'touchnotouch',
                duration          => '1W',
                expiry_type       => 'daily'
            },
            ticks => [
                [$date->minus_time_interval('400d')],
                [$date,                            1.1521],
                [$date->plus_time_interval(1),     1.14621],
                [$date->plus_time_interval(3),     1.15799],
                [$date->plus_time_interval('10m'), 1.15591]
            ],
            available_barriers => [1.13005, 1.13495, 1.13985, 1.14622, 1.15798, 1.16435, 1.16925, 1.17415,],
            expired_barriers   => [1.14622, 1.15798],
        },
        {
            match => {
                contract_category => 'staysinout',
                duration          => '1W',
                expiry_type       => 'daily'
            },
            ticks => [
                [$date->minus_time_interval('400d')],
                [$date,                            1.1521],
                [$date->plus_time_interval(1),     1.13984],
                [$date->plus_time_interval(3),     1.15667],
                [$date->plus_time_interval('10m'), 1.15591]
            ],
            available_barriers => [[1.13985, 1.16435], [1.13495, 1.16925], [1.13005, 1.17415]],
            expired_barriers => [[1.13985, 1.16435]],
        },
        {
            match => {
                contract_category => 'endsinout',
                duration          => '1W',
                expiry_type       => 'daily'
            },
            ticks => [
                [$date->minus_time_interval('400d')],
                [$date,                            1.1521],
                [$date->plus_time_interval(1),     1.1520],
                [$date->plus_time_interval(3),     1.15667],
                [$date->plus_time_interval('10m'), 1.15591]
            ],
            available_barriers => [
                [1.16435,   1.17415],
                [1.15798,   1.16925],
                ["1.15210", 1.16435],
                [1.14622,   1.15798],
                [1.13985,   "1.15210"],
                [1.13495,   1.14622],
                [1.13005,   1.13985],
            ],
            expired_barriers => [],
        },
    );

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $symbol,
            recorded_date => $date
        });

    my $generation_date = $date->plus_time_interval('1h');
    my $tp = BOM::Test::Data::Utility::UnitTestMarketData::create_trading_periods($symbol, $generation_date);

    foreach my $test (@inputs) {
        setup_ticks($symbol, $test->{ticks});
        BOM::Test::Data::Utility::UnitTestMarketData::create_predefined_barriers($symbol, $_, $generation_date) for @$tp;
        my $offerings = BOM::Product::ContractFinder->new(for_date => $generation_date)->multi_barrier_contracts_for({
                symbol => $symbol,
            })->{available};
        my $m        = $test->{match};
        my $offering = first {
            $_->{expiry_type} eq $m->{expiry_type}
                and $_->{contract_category} eq $m->{contract_category}
                and $_->{trading_period}->{duration} eq $m->{duration}
        }
        @$offerings;
        my $testname = join '_', map { $m->{$_} } qw(contract_category expiry_type duration);
        cmp_bag($offering->{available_barriers}, $test->{available_barriers}, 'available barriers for ' . $testname);
        cmp_bag($offering->{expired_barriers},   $test->{expired_barriers},   'expired barriers for ' . $testname);
    }
};

subtest 'update_predefined_highlow' => sub {
    my $now    = Date::Utility->new;
    my $symbol = 'frxGBPUSD';
    SKIP: {
        my $u = create_underlying($symbol);
        skip 'non trading day', 4, unless $u->calendar->trades_on($u->exchange, $now);
        setup_ticks($symbol, [[$now->minus_time_interval('365d'), 100], [$now, 69], [$now->plus_time_interval('10s'), 69.1]]);
        my $new_tick = {
            symbol => $symbol,
            epoch  => $now->plus_time_interval('30s')->epoch,
            quote  => 69.2
        };
        my $tp = BOM::Test::Data::Utility::UnitTestMarketData::create_trading_periods($symbol, $now);
        BOM::Test::Data::Utility::UnitTestMarketData::create_predefined_barriers($symbol, $_, $now) for @$tp;
        ok update_predefined_highlow($new_tick), 'updated highlow';
        my $offering = BOM::Product::ContractFinder->new->multi_barrier_contracts_for({symbol => $symbol})->{available};
        my $touch = first { $_->{contract_category} eq 'touchnotouch' and $_->{trading_period}->{duration} eq '3M' } @$offering;
        ok !scalar(@{$touch->{expired_barriers}}), 'no expired barrier detected';
        $new_tick->{epoch} += 1;
        $new_tick->{quote} = 125;
        ok update_predefined_highlow($new_tick), 'next update';
        $offering = BOM::Product::ContractFinder->new->multi_barrier_contracts_for({symbol => $symbol})->{available};
        $touch = first { $_->{contract_category} eq 'touchnotouch' and $_->{trading_period}->{duration} eq '3M' } @$offering;
        ok scalar(@{$touch->{expired_barriers}}), 'expired barrier detected';
    }
};

subtest 'get_expired_barriers' => sub {
    my $time      = time;
    my $mocked_pp = Test::MockModule->new('BOM::Product::Contract::PredefinedParameters');
    $mocked_pp->mock('_get_predefined_highlow', sub { (100, 99) });
    my $mocked_u = Test::MockModule->new('Quant::Framework::Underlying');
    $mocked_u->mock(
        'spot_tick',
        sub {
            Postgres::FeedDB::Spot::Tick->new({
                symbol => 'frxUSDJPY',
                quote  => 100,
                epoch  => $time,
            });
        });

    my $underlying = Quant::Framework::Underlying->new('frxUSDJPY');
    my $tp         = {
        date_start => {
            epoch => $time,
            date  => Date::Utility->new($time)->datetime
        },
        date_expiry => {
            epoch => $time + 3600,
            date  => Date::Utility->new($time + 3600)->datetime
        }};

    ok !@{get_expired_barriers($underlying, [101], $tp)}, 'not expired barrier';
    is get_expired_barriers($underlying, [99.5], $tp)->[0], 99.5, 'has expired barrier[99.5]';
    $mocked_pp->mock('_get_predefined_highlow', sub { () });
    $mocked_u->mock(
        'spot_tick',
        sub {
            Postgres::FeedDB::Spot::Tick->new({
                symbol => 'frxUSDJPY',
                quote  => 100,
                epoch  => $time - 1,
            });
        });
    ok get_expired_barriers($underlying, [99.5], $tp), 'no warnings if latest tick is before trading period start';
    $mocked_u->mock(
        'spot_tick',
        sub {
            Postgres::FeedDB::Spot::Tick->new({
                symbol => 'frxUSDJPY',
                quote  => 100,
                epoch  => $time,
            });
        });
    warning_like { get_expired_barriers($underlying, [99.5], $tp) } qr/highlow is undefined for frxUSDJPY/, 'warns';
};

sub setup_ticks {
    my ($symbol, $data) = @_;

    BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables();
    foreach my $d (@$data) {
        my ($date, $quote) = map { $d->[$_] } (0, 1);
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => $symbol,
            epoch      => $date->epoch,
            $quote ? (quote => $quote) : (),
        });
        # simulate distributor work
        if ($quote) {
            BOM::Platform::RedisReplicated::redis_write()->set(
                "Distributor::QUOTE::$symbol",
                Encode::encode_utf8(
                    JSON::MaybeXS->new->encode({
                            quote => $quote,
                            epoch => $date->epoch,
                        })));
        }
    }
}

done_testing();
