#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::FailWarnings;

use BOM::MarketData qw(create_underlying);
use List::Util qw(first);
use Date::Utility;
use BOM::Product::Contract::PredefinedParameters qw(generate_trading_periods get_predefined_offerings);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

my $supported_symbol = 'frxUSDJPY';
my $monday           = Date::Utility->new('2016-11-14');    # monday

subtest 'non trading day' => sub {
    my $saturday = Date::Utility->new('2016-11-19');                               # saturday
    generate_trading_periods($supported_symbol, $saturday);
    my $offerings = get_predefined_offerings($supported_symbol, $saturday);
    ok !@$offerings, 'no offerings were generated on non trading day';
    setup_ticks($supported_symbol, [[$monday->minus_time_interval('100d')], [$monday]]);
    generate_trading_periods($supported_symbol, $monday);
    $offerings = get_predefined_offerings($supported_symbol, $monday);
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
            'frxUSDJPY', 'callput', '2016-11-14 00:00:00',
            2, [['2016-11-14 00:00:00', '2016-11-14 02:00:00'], ['2016-11-14 00:00:00', '2016-11-14 02:00:00']]
        ],
        # monday at 00:44GMT
        [
            'frxUSDJPY', 'callput', '2016-11-14 00:44:00',
            2, [['2016-11-14 00:00:00', '2016-11-14 02:00:00'], ['2016-11-14 00:00:00', '2016-11-14 02:00:00']]
        ],
        # monday at 00:45GMT
        [
            'frxUSDJPY',
            'callput',
            '2016-11-14 00:45:00',
            4,
            [
                ['2016-11-14 00:00:00', '2016-11-14 02:00:00'],
                ['2016-11-14 00:45:00', '2016-11-14 06:00:00'],
                ['2016-11-14 00:00:00', '2016-11-14 02:00:00'],
                ['2016-11-14 00:45:00', '2016-11-14 06:00:00']]
        ],
        # monday at 01:45GMT
        [
            'frxUSDJPY',
            'callput',
            '2016-11-14 01:45:00',
            6,
            [
                ['2016-11-14 00:00:00', '2016-11-14 02:00:00'],
                ['2016-11-14 01:45:00', '2016-11-14 04:00:00'],
                ['2016-11-14 00:45:00', '2016-11-14 06:00:00'],
                ['2016-11-14 00:00:00', '2016-11-14 02:00:00'],
                ['2016-11-14 01:45:00', '2016-11-14 04:00:00'],
                ['2016-11-14 00:45:00', '2016-11-14 06:00:00']]
        ],
        # monday at 02:00GMT
        [
            'frxUSDJPY',
            'callput',
            '2016-11-14 02:00:00',
            4,
            [
                ['2016-11-14 01:45:00', '2016-11-14 04:00:00'],
                ['2016-11-14 00:45:00', '2016-11-14 06:00:00'],
                ['2016-11-14 01:45:00', '2016-11-14 04:00:00'],
                ['2016-11-14 00:45:00', '2016-11-14 06:00:00']]
        ],
        # monday at 18:00GMT
        ['frxUSDJPY', 'callput', '2016-11-14 18:00:00', 0, [],],
        # monday at 21:44GMT
        ['frxUSDJPY', 'callput', '2016-11-14 21:44:00', 0, [],],
        # monday at 21:45GMT
        [
            'frxUSDJPY', 'callput', '2016-11-14 21:45:00',
            2, [['2016-11-14 21:45:00', '2016-11-14 23:59:59'], ['2016-11-14 21:45:00', '2016-11-14 23:59:59'],],
        ],
        # monday at 21:45GMT
        ['frxGBPJPY', 'callput', '2016-11-14 21:45:00', 0, [],],
    );

    foreach my $input (@test_inputs) {
        my ($symbol, $category, $date, $count, $periods) = map { $input->[$_] } (0 .. 4);
        $date = Date::Utility->new($date);
        setup_ticks($symbol, [[$date->minus_time_interval('100d')], [$date]]);
        note('generating for ' . $symbol . '. Time set to ' . $date->day_as_string . ' at ' . $date->time);
        generate_trading_periods($symbol, $date);
        my $offerings = get_predefined_offerings($symbol, $date);
        my @intraday = grep { $_->{expiry_type} eq 'intraday' } @$offerings;
        is scalar(@intraday), $count, 'expected two offerings on intraday at 00:00GMT';

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
    setup_ticks($symbol, [[$date->minus_time_interval('100d')], [$date, 1.1521], [$date->plus_time_interval('10m'), 1.15591]]);

    my @inputs = ({
            match => {
                contract_category => 'callput',
                duration          => '5h15m',
                expiry_type       => 'intraday'
            },
            ticks => [[$date->minus_time_interval('100d')], [$date, 1.1521], [$date->plus_time_interval('10m'), 1.15591]],
            available_barriers => [1.15015, 1.15207, 1.15303, 1.15399, 1.15495, 1.15591, 1.15687, 1.15783, 1.15879, 1.15975, 1.16167],
            expired_barriers   => [],
        },
        {
            match => {
                contract_category => 'touchnotouch',
                duration          => '1W',
                expiry_type       => 'daily'
            },
            ticks => [
                [$date->minus_time_interval('100d')],
                [$date,                            1.1521],
                [$date->plus_time_interval(1),     1.1520],
                [$date->plus_time_interval(3),     1.15667],
                [$date->plus_time_interval('10m'), 1.15591]
            ],
            available_barriers => [1.12474, 1.13386, 1.13842, 1.14298, 1.14754, 1.1521, 1.15666, 1.16122, 1.16578, 1.17034, 1.17946],
            expired_barriers   => [1.1521, 1.15666],
        },
        {
             match => {
                 contract_category => 'staysinout',
                 duration          => '1W',
                 expiry_type       => 'daily'
             },
             ticks => [
                 [$date->minus_time_interval('100d')],
                 [$date,                            1.1521],
                 [$date->plus_time_interval(1),     1.1520],
                 [$date->plus_time_interval(3),     1.15667],
                 [$date->plus_time_interval('10m'), 1.15591]
             ],
             available_barriers => [[1.14754, 1.15666], [1.14298, 1.16122], [1.13842, 1.16578], [1.13386, 1.17034]],
             expired_barriers => [[1.14754, 1.15666]],
        },
        {
             match => {
                 contract_category => 'endsinout',
                 duration          => '1W',
                 expiry_type       => 'daily'
             },
             ticks => [
                 [$date->minus_time_interval('100d')],
                 [$date,                            1.1521],
                 [$date->plus_time_interval(1),     1.1520],
                 [$date->plus_time_interval(3),     1.15667],
                 [$date->plus_time_interval('10m'), 1.15591]
             ],
            available_barriers => [
                [1.14754, 1.15666],
                [1.14298, 1.1521],
                [1.1521, 1.16122],
                [1.13842, 1.14754],
                [1.15666, 1.16578],
                [1.13386, 1.14298],
                [1.16122, 1.17034],
                [1.12474, 1.13842],
                [1.16578 ,1.17946]
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
    generate_trading_periods($symbol, $generation_date);

    foreach my $test (@inputs) {
        setup_ticks($symbol, $test->{ticks});
        my $offerings = get_predefined_offerings($symbol, $generation_date);
        my $m        = $test->{match};
        my $offering = first {
            $_->{expiry_type} eq $m->{expiry_type}
                and $_->{contract_category} eq $m->{contract_category}
                and $_->{trading_period}->{duration} eq $m->{duration}
        }
        @$offerings;
        my $testname = join '_', map {$m->{$_}} qw(contract_category expiry_type duration);
        cmp_bag($offering->{available_barriers}, $test->{available_barriers}, 'available barriers for ' . $testname);
        cmp_bag($offering->{expired_barriers},    $test->{expired_barriers},   'expired barriers for ' . $testname);
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
    }
}

done_testing();
