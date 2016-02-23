#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 6;
use Test::Exception;
use Test::NoWarnings;
use Test::Deep;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Product::Contract::Finder::Japan qw(available_contracts_for_symbol);
use BOM::Product::Offerings qw(get_offerings_flyby);
use BOM::Market::Underlying;
use Date::Utility;
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency', {symbol => $_}) for qw(USD JPY AUD CAD EUR);
subtest "predefined contracts for symbol" => sub {
    my $now = Date::Utility->new('2015-08-21 05:30:00');

    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'holiday',
        {
            recorded_date => $now,
            calendar      => {
                "01-Jan-15" => {
                    "Christmas Day" => ['FOREX'],
                },
            },
        });
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $now
        }) for qw(frxUSDJPY frxAUDCAD frxUSDCAD frxAUDUSD);

    my %expected = (
        frxUSDJPY => {
            contract_count => {
                callput      => 16,
                touchnotouch => 8,
                staysinout   => 8,
                endsinout    => 10,
            },
            hit_count => 42,
        },
        frxAUDCAD => {hit_count => 0},
    );
    foreach my $u (keys %expected) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => $u,
            epoch      => $now->epoch,
            quote      => 100
        });
        my $f = available_contracts_for_symbol({
            symbol => $u,
            date   => $now
        });
        my %got;
        $got{$_->{contract_category}}++ for (@{$f->{available}});
        is($f->{hit_count}, $expected{$u}{hit_count}, "Expected total contract for $u");
        cmp_ok $got{$_}, '==', $expected{$u}{contract_count}{$_}, "Expected total contract  for $u on this $_ type"
            for (keys %{$expected{$u}{contract_count}});
    }
};
subtest "predefined trading_period" => sub {
    my %expected_count = (
        offering                                => 12,
        offering_with_predefined_trading_period => 40,
        trading_period                          => {
            call_intraday => 2,
            call_daily    => 5,
            range_daily   => 4,
        });

    my %expected_trading_period = (
        call_intraday => {
            duration => ['2h15m', '5h15m'],
            date_expiry => [map { Date::Utility->new($_)->epoch } ('2015-09-04 18:00:00', '2015-09-04 18:00:00',)],
            date_start  => [map { Date::Utility->new($_)->epoch } ('2015-09-04 15:45:00', '2015-09-04 12:45:00',)],
        },
        range_daily => {
            duration => ['1W', '1M', '3M', '1Y'],
            date_expiry =>
                [map { Date::Utility->new($_)->epoch } ('2015-09-04 21:00:00', '2015-09-30 23:59:59', '2015-09-30 23:59:59', '2015-12-31 23:59:59',)],
            date_start =>
                [map { Date::Utility->new($_)->epoch } ('2015-08-31 00:00:00', '2015-09-01 00:00:00', '2015-07-01 00:00:00', '2015-01-02 00:00:00',)],
        },
    );

    my $flyby     = BOM::Product::Offerings::get_offerings_flyby;
    my @offerings = $flyby->query({
            underlying_symbol => 'frxUSDJPY',
            start_type        => 'spot',
            expiry_type       => ['daily', 'intraday'],
            barrier_category  => ['euro_non_atm', 'american']});
    is(scalar(keys @offerings), $expected_count{'offering'}, 'Expected total contract before included predefined trading period');
    my $exchange = BOM::Market::Underlying->new('frxUSDJPY')->exchange;
    my $now      = Date::Utility->new('2015-09-04 17:00:00');
    @offerings = BOM::Product::Contract::Finder::Japan::_predefined_trading_period({
        offerings => \@offerings,
        exchange  => $exchange,
        date      => $now,
        symbol    => 'frxUSDJPY',
    });

    my %got;
    foreach (keys @offerings) {
        $offerings[$_]{contract_type} eq 'CALL'
            and $offerings[$_]{expiry_type} eq 'intraday' ? push @{$got{call_intraday}}, $offerings[$_]{trading_period} : push @{$got{call_daily}},
            $offerings[$_]{trading_period};
        $offerings[$_]{contract_type} eq 'RANGE'
            and $offerings[$_]{expiry_type} eq 'intraday' ? push @{$got{range_intraday}}, $offerings[$_]{trading_period} : push @{$got{range_daily}},
            $offerings[$_]{trading_period};
    }
    is(
        scalar(keys @offerings),
        $expected_count{'offering_with_predefined_trading_period'},
        'Expected total contract after included predefined trading period'
    );
    is(scalar(@{$got{$_}}), $expected_count{trading_period}{$_}, "Expected total trading period on $_") for (keys %{$expected_count{trading_period}});
    foreach my $bet_type (keys %expected_trading_period) {

        my @got_duration = map { $got{$bet_type}[$_]{duration} } keys $got{$bet_type};
        cmp_deeply(\@got_duration, $expected_trading_period{$bet_type}{duration}, "Expected duration for $bet_type");
        my @got_date_start = map { $got{$bet_type}[$_]{date_start}{epoch} } keys $got{$bet_type};
        cmp_deeply(\@got_date_start, $expected_trading_period{$bet_type}{date_start}, "Expected date_start for $bet_type");

        my @got_date_expiry = map { $got{$bet_type}[$_]{date_expiry}{epoch} } keys $got{$bet_type};
        cmp_deeply(\@got_date_expiry, $expected_trading_period{$bet_type}{date_expiry}, "Expected date_expiry for $bet_type");
    }
};

subtest "check_intraday trading_period_JPY" => sub {
    my %expected_intraday_trading_period = (
        # monday
        '2015-11-23 00:00:00' => {
            date_start  => [Date::Utility->new('2015-11-23 00:00:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-23 02:00:00')->epoch],
        },
        '2015-11-23 01:00:00' => {
            date_start  => [map { Date::Utility->new($_)->epoch } ('2015-11-23 00:00:00', '2015-11-23 00:45:00',)],
            date_expiry => [map { Date::Utility->new($_)->epoch } ('2015-11-23 02:00:00', '2015-11-23 06:00:00',)],

        },
        '2015-11-23 18:00:00' => {},
        '2015-11-23 22:00:00' => {
            date_start  => [Date::Utility->new('2015-11-23 21:45:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-24 00:00:00')->epoch],
        },
        # tues
        '2015-11-24 00:00:00' => {
            date_start  => [Date::Utility->new('2015-11-23 23:45:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-24 02:00:00')->epoch],
        },
        '2015-11-24 01:00:00' => {
            date_start  => [map { Date::Utility->new($_)->epoch } ('2015-11-23 23:45:00', '2015-11-24 00:45:00',)],
            date_expiry => [map { Date::Utility->new($_)->epoch } ('2015-11-24 02:00:00', '2015-11-24 06:00:00',)],

        },
        '2015-11-24 21:00:00' => {},
        '2015-11-24 23:00:00' => {
            date_start  => [Date::Utility->new('2015-11-24 21:45:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-25 00:00:00')->epoch],
        },
        # Friday
        '2015-11-27 00:00:00' => {
            date_start  => [Date::Utility->new('2015-11-26 23:45:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-27 02:00:00')->epoch],
        },
        '2015-11-27 02:00:00' => {
            date_start  => [map { Date::Utility->new($_)->epoch } ('2015-11-27 01:45:00', '2015-11-27 00:45:00',)],
            date_expiry => [map { Date::Utility->new($_)->epoch } ('2015-11-27 04:00:00', '2015-11-27 06:00:00',)],

        },
        '2015-11-27 18:00:00' => {},
        '2015-11-27 19:00:00' => {},
    );

    my @i_offerings = BOM::Product::Offerings::get_offerings_flyby->query({
            underlying_symbol => 'frxUSDJPY',
            start_type        => 'spot',
            expiry_type       => ['intraday'],
            barrier_category  => ['euro_non_atm']});
    my $ex = BOM::Market::Underlying->new('frxUSDJPY')->exchange;
    foreach my $date (keys %expected_intraday_trading_period) {
        my $now                = Date::Utility->new($date);
        my @intraday_offerings = BOM::Product::Contract::Finder::Japan::_predefined_trading_period({
            offerings => \@i_offerings,
            exchange  => $ex,
            date      => $now,
            symbol    => 'frxUSDJPY',
        });
        cmp_deeply(
            $intraday_offerings[0]{trading_period}{date_expiry}{epoch},
            $expected_intraday_trading_period{$date}{date_expiry}[0],
            "Expected date_expiry for $date"
        );
        cmp_deeply(
            $intraday_offerings[0]{trading_period}{date_start}{epoch},
            $expected_intraday_trading_period{$date}{date_start}[0],
            "Expected date_start for $date"
        );
    }

};
subtest "check_intraday trading_period_non_JPY" => sub {
    my %expected_eur_intraday_trading_period = (
        # monday
        '2015-11-23 00:00:00' => {
            date_start  => [Date::Utility->new('2015-11-23 00:00:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-23 02:00:00')->epoch],
        },
        '2015-11-23 18:00:00' => {},
        '2015-11-23 22:00:00' => {},
        # tues
        '2015-11-24 00:00:00' => {
            date_start  => [Date::Utility->new('2015-11-23 23:45:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-24 02:00:00')->epoch],
        },
        '2015-11-24 21:00:00' => {},
        '2015-11-24 23:00:00' => {},
        # Friday
        '2015-11-27 18:00:00' => {},
        '2015-11-27 19:00:00' => {},
    );

    my @e_offerings = BOM::Product::Offerings::get_offerings_flyby->query({
            underlying_symbol => 'frxEURUSD',
            start_type        => 'spot',
            expiry_type       => ['intraday'],
            barrier_category  => ['euro_non_atm']});
    my $ex = BOM::Market::Underlying->new('frxEURUSD')->exchange;
    foreach my $date (keys %expected_eur_intraday_trading_period) {
        my $now              = Date::Utility->new($date);
        my @eurusd_offerings = BOM::Product::Contract::Finder::Japan::_predefined_trading_period({
            offerings => \@e_offerings,
            exchange  => $ex,
            date      => $now,
            symbol    => 'frxEURUSD',
        });

        cmp_deeply(
            $eurusd_offerings[0]{trading_period}{date_expiry}{epoch},
            $expected_eur_intraday_trading_period{$date}{date_expiry}[0],
            "Expected date_expiry for $date"
        );
        cmp_deeply(
            $eurusd_offerings[0]{trading_period}{date_start}{epoch},
            $expected_eur_intraday_trading_period{$date}{date_start}[0],
            "Expected date_start for $date"
        );
    }

};
subtest "predefined barriers" => sub {

    my %expected_barriers = (
        call_intraday => {
            available_barriers => [1.15441, 1.15591, 1.15491, 1.16041, 1.15891, 1.15291, 1.15691, 1.15541, 1.15741, 1.15641, 1.15141],
            barrier            => 1.15591,
        },
        range_daily => {
            available_barriers => [[1.15436, 1.15746], [1.15281, 1.15901], [1.15126, 1.16056], [1.14661, 1.16521], [1.14196, 1.16986]],
        },
        expiryrange_daily => {
            available_barriers => [
                [1.15436, 1.16056],
                [1.15281, 1.15591],
                [1.15591, 1.15901],
                [1.15126, 1.15436],
                [1.15746, 1.16056],
                [1.14661, 1.15281],
                [1.15901, 1.16521]
            ],
        },

    );

    my $contract = {
        trading_period => {
            date_start => {
                epoch => 1440374400,
                date  => '2015-08-24 00:45:00'
            },
            date_expiry => {
                epoch => 1440392400,
                date  => '2015-08-24 06:00:00'
            },
            duration => '5h15m',
        },
        barriers => 1,
    };
    my $underlying = BOM::Market::Underlying->new('frxEURUSD');
    my $now        = Date::Utility->new('2015-08-24 00:00:00');
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxEURUSD',
        epoch      => $now->epoch,
        quote      => 1.15591,
    });
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxEURUSD',
            recorded_date => $now
        });
    BOM::Product::Contract::Finder::Japan::_set_predefined_barriers({
        underlying   => $underlying,
        contract     => $contract,
        current_tick => $underlying->tick_at($now),
        date         => $now
    });
    cmp_bag(
        $contract->{available_barriers},
        $expected_barriers{call_intraday}{available_barriers},
        "Expected available barriers for intraday call"
    );
    is($contract->{barrier}, $expected_barriers{call_intraday}{barrier}, "Expected default barrier for intraday call");

    my $contract_2 = {
        trading_period => {
            date_start => {
                epoch => 1440374400,
                date  => '2015-08-24 00:00:00'
            },
            date_expiry => {
                epoch => 1440547199,
                date  => '2015-08-25 23:59:59'
            },
            duration => '1d',
        },
        barriers          => 2,
        contract_category => 'staysinout',
    };
    BOM::Product::Contract::Finder::Japan::_set_predefined_barriers({
        underlying   => $underlying,
        contract     => $contract_2,
        current_tick => $underlying->tick_at($now),
        date         => $now
    });
    cmp_deeply(
        $contract_2->{available_barriers}[$_],
        $expected_barriers{range_daily}{available_barriers}[$_],
        "Expected available barriers for daily range"
    ) for keys @{$expected_barriers{range_daily}{available_barriers}};

    my $contract_3 = {
        trading_period => {
            date_start => {
                epoch => 1440374400,
                date  => '2015-08-24 00:00:00'
            },
            date_expiry => {
                epoch => 1440547199,
                date  => '2015-08-25 23:59:59'
            },
            duration => '1d',
        },
        barriers          => 2,
        contract_category => 'endsinout',
    };
    BOM::Product::Contract::Finder::Japan::_set_predefined_barriers({
        underlying   => $underlying,
        contract     => $contract_3,
        current_tick => $underlying->tick_at($now),
        date         => $now
    });
    cmp_deeply(
        $contract_3->{available_barriers}[$_],
        $expected_barriers{expiryrange_daily}{available_barriers}[$_],
        "Expected available barriers for daily expiry range"
    ) for keys @{$expected_barriers{expiryrange_daily}{available_barriers}};

};

