#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warnings;

use Cache::RedisDB;
use List::Util qw(first);
use Date::Utility;
use JSON::MaybeXS;
use LandingCompany::Offerings qw(reinitialise_offerings);

use BOM::MarketData qw(create_underlying);
use BOM::Product::Contract::PredefinedParameters qw(get_predefined_offerings update_predefined_highlow);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);

my $supported_symbol = 'frxUSDJPY';
my $monday           = Date::Utility->new('2016-11-14');    # monday

subtest 'non trading day' => sub {
    my $saturday = Date::Utility->new('2016-11-19');        # saturday
    BOM::Test::Data::Utility::UnitTestMarketData::create_trading_periods($supported_symbol, $saturday);
    my $offerings = get_predefined_offerings({
        symbol => $supported_symbol,
        date   => $saturday
    });
    ok !@$offerings, 'no offerings were generated on non trading day';
    setup_ticks($supported_symbol, [[$monday->minus_time_interval('400d')], [$monday]]);
    BOM::Test::Data::Utility::UnitTestMarketData::create_trading_periods($supported_symbol, $monday);
    $offerings = get_predefined_offerings({
        symbol => $supported_symbol,
        date   => $monday
    });
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
        my $offerings = get_predefined_offerings({
            symbol => $symbol,
            date   => $date
        });
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
    BOM::Test::Data::Utility::UnitTestMarketData::create_trading_periods($symbol, $generation_date);

    foreach my $test (@inputs) {
        setup_ticks($symbol, $test->{ticks});
        my $offerings = get_predefined_offerings({
            symbol => $symbol,
            date   => $generation_date
        });
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
        ok update_predefined_highlow($new_tick), 'updated highlow';
        my $offering = get_predefined_offerings({symbol => $symbol});
        my $touch = first { $_->{contract_category} eq 'touchnotouch' and $_->{trading_period}->{duration} eq '3M' } @$offering;
        ok !scalar(@{$touch->{expired_barriers}}), 'no expired barrier detected';
        $new_tick->{epoch} += 1;
        $new_tick->{quote} = 125;
        ok update_predefined_highlow($new_tick), 'next update';
        $offering = get_predefined_offerings({symbol => $symbol});
        $touch = first { $_->{contract_category} eq 'touchnotouch' and $_->{trading_period}->{duration} eq '3M' } @$offering;
        ok scalar(@{$touch->{expired_barriers}}), 'expired barrier detected';
    }
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
                Encode::encode_utf8(JSON::MaybeXS->new->encode({
                        quote => $quote,
                        epcoh => $date->epoch,
                    })));
        }
    }
}

done_testing();
