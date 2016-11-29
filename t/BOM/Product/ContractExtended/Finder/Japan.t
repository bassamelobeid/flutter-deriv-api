#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 5;
use Test::Exception;
use Test::Deep;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Product::Contract::Finder::Japan qw(available_contracts_for_symbol);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Date::Utility;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD JPY AUD CAD EUR);
subtest "predefined contracts for symbol" => sub {
    my $now = Date::Utility->new('2015-08-21 05:30:00');

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'holiday',
        {
            recorded_date => $now,
            calendar      => {
                "01-Jan-15" => {
                    "Christmas Day" => ['FOREX'],
                },
            },
        });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $now
        }) for qw(frxUSDJPY frxAUDCAD frxUSDCAD frxAUDUSD);

    my %expected = (
        frxUSDJPY => {
            contract_count => {
                callput      => 14,
                touchnotouch => 6,
                staysinout   => 6,
                endsinout    => 6,
            },
            hit_count => 32,
        },
        frxAUDCAD => {hit_count => 0},
    );
    foreach my $u (keys %expected) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                underlying => $u,
                epoch      => Date::Utility->new($_)->epoch,
                quote      => 100,
            })
            for (
            "2015-01-01",          "2015-07-01",          "2015-08-03",          "2015-08-17", "2015-08-21",
            "2015-08-21 00:45:00", "2015-08-21 03:45:00", "2015-08-21 04:45:00", "2015-08-21 05:30:00"
            );

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
        offering                                => 10,
        offering_with_predefined_trading_period => 30,
        trading_period                          => {
            call_intraday => 2,
            call_daily    => 4,
            range_daily   => 3,
        });

    my %expected_trading_period = (
        call_intraday => {
            duration => ['2h15m', '5h15m'],
            date_expiry => [map { Date::Utility->new($_)->epoch } ('2015-09-04 18:00:00', '2015-09-04 18:00:00',)],
            date_start  => [map { Date::Utility->new($_)->epoch } ('2015-09-04 15:45:00', '2015-09-04 12:45:00',)],
        },
        range_daily => {
            duration => ['1W', '1M', '3M'],
            date_expiry => [map { Date::Utility->new($_)->epoch } ('2015-09-04 21:00:00', '2015-09-30 23:59:59', '2015-09-30 23:59:59',)],
            date_start  => [map { Date::Utility->new($_)->epoch } ('2015-08-31 00:00:00', '2015-09-01 00:00:00', '2015-07-01 00:00:00',)],
        },
    );

    my @offerings = BOM::Product::Contract::Finder::Japan::get_offerings('frxUSDJPY');
    is(scalar(@offerings), $expected_count{'offering'}, 'Expected total contract before included predefined trading period');
    my $calendar = create_underlying('frxUSDJPY')->calendar;
    my $now      = Date::Utility->new('2015-09-04 17:00:00');
    @offerings = BOM::Product::Contract::Finder::Japan::_predefined_trading_period({
        offerings => \@offerings,
        calendar  => $calendar,
        date      => $now,
        symbol    => 'frxUSDJPY',
    });

    my %got;
    foreach (keys @offerings) {
        $offerings[$_]{contract_type} eq 'CALLE'
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

        my @got_duration = map { $_->{duration} } @{$got{$bet_type}};
        cmp_deeply(\@got_duration, $expected_trading_period{$bet_type}{duration}, "Expected duration for $bet_type");
        my @got_date_start = map { $_->{date_start}{epoch} } @{$got{$bet_type}};
        cmp_deeply(\@got_date_start, $expected_trading_period{$bet_type}{date_start}, "Expected date_start for $bet_type");

        my @got_date_expiry = map { $_->{date_expiry}{epoch} } @{$got{$bet_type}};
        cmp_deeply(\@got_date_expiry, $expected_trading_period{$bet_type}{date_expiry}, "Expected date_expiry for $bet_type");
    }
};

subtest "check_intraday trading_period_JPY" => sub {
    my %expected_intraday_trading_period = (
        # monday
        '2015-11-23 00:00:00' => {
            combination => 1,                                                    # one call and one put
            date_start  => [Date::Utility->new('2015-11-23 00:00:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-23 02:00:00')->epoch],
        },
        '2015-11-23 01:00:00' => {
            combination => 2,
            date_start  => [map { Date::Utility->new($_)->epoch } ('2015-11-23 00:00:00', '2015-11-23 00:45:00',)],
            date_expiry => [map { Date::Utility->new($_)->epoch } ('2015-11-23 02:00:00', '2015-11-23 06:00:00',)],

        },
        '2015-11-23 18:00:00' => {combination => 0},
        '2015-11-23 21:45:00' => {
            combination => 1,
            date_start  => [Date::Utility->new('2015-11-23 21:45:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-23 23:59:59')->epoch],
        },

        '2015-11-23 22:00:00' => {
            combination => 1,
            date_start  => [Date::Utility->new('2015-11-23 21:45:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-23 23:59:59')->epoch],
        },
        '2015-11-23 23:45:00' => {
            combination => 2,
            date_start  => [map { Date::Utility->new($_)->epoch } ('2015-11-23 21:45:00', '2015-11-23 23:45:00',)],
            date_expiry => [map { Date::Utility->new($_)->epoch } ('2015-11-23 23:59:59', '2015-11-24 02:00:00',)],
        },

        # tues
        '2015-11-24 00:00:00' => {
            combination => 1,
            date_start  => [Date::Utility->new('2015-11-23 23:45:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-24 02:00:00')->epoch],
        },
        '2015-11-24 01:00:00' => {
            combination => 2,
            date_start  => [map { Date::Utility->new($_)->epoch } ('2015-11-23 23:45:00', '2015-11-24 00:45:00',)],
            date_expiry => [map { Date::Utility->new($_)->epoch } ('2015-11-24 02:00:00', '2015-11-24 06:00:00',)],

        },
        '2015-11-24 21:00:00' => {combination => 0},
        '2015-11-24 23:00:00' => {
            combination => 1,
            date_start  => [Date::Utility->new('2015-11-24 21:45:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-24 23:59:59')->epoch],
        },
        # Friday
        '2015-11-27 00:00:00' => {
            combination => 1,
            date_start  => [Date::Utility->new('2015-11-26 23:45:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-27 02:00:00')->epoch],
        },
        '2015-11-27 02:00:00' => {
            combination => 2,
            date_start  => [map { Date::Utility->new($_)->epoch } ('2015-11-27 01:45:00', '2015-11-27 00:45:00',)],
            date_expiry => [map { Date::Utility->new($_)->epoch } ('2015-11-27 04:00:00', '2015-11-27 06:00:00',)],

        },
        '2015-11-27 18:00:00' => {
            combination => 0,
        },
        '2015-11-27 19:00:00' => {
            combination => 0,
        },

    );

    my @i_offerings =
        grep { $_->{expiry_type} eq 'intraday' and $_->{contract_type} eq 'CALLE' } BOM::Product::Contract::Finder::Japan::get_offerings('frxUSDJPY');
    my $ex = create_underlying('frxUSDJPY')->calendar;
    foreach my $date (keys %expected_intraday_trading_period) {
        my $now                = Date::Utility->new($date);
        my @intraday_offerings = BOM::Product::Contract::Finder::Japan::_predefined_trading_period({
            offerings => \@i_offerings,
            calendar  => $ex,
            date      => $now,
            symbol    => 'frxUSDJPY',
        });

        my @got_date_start  = map { $intraday_offerings[$_]{trading_period}{date_start}{epoch} } keys @intraday_offerings;
        my @got_date_expiry = map { $intraday_offerings[$_]{trading_period}{date_expiry}{epoch} } keys @intraday_offerings;

        is(
            scalar @intraday_offerings,
            $expected_intraday_trading_period{$date}{combination},
            "Matching expected intraday combination on USDJPY for $date"
        );

        if (scalar @intraday_offerings > 1) {
            cmp_deeply(\@got_date_start, $expected_intraday_trading_period{$date}{date_start}, "Expected date_start for $date");

            cmp_deeply(\@got_date_expiry, $expected_intraday_trading_period{$date}{date_expiry}, "Expected date_expiry for $date");
        }
    }

};
subtest "check_intraday trading_period_non_JPY" => sub {
    my %expected_eur_intraday_trading_period = (
        # monday
        '2015-11-23 00:00:00' => {
            combination => 1,
            date_start  => [Date::Utility->new('2015-11-23 00:00:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-23 02:00:00')->epoch],
        },
        '2015-11-23 18:00:00' => {combination => 0},
        '2015-11-23 22:00:00' => {combination => 0},
        '2015-11-23 23:45:00' => {
            combination => 1,
            date_start  => [Date::Utility->new('2015-11-23 23:45:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-23 02:00:00')->epoch],
        },

        # tues
        '2015-11-24 00:00:00' => {
            combination => 1,
            date_start  => [Date::Utility->new('2015-11-23 23:45:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-24 02:00:00')->epoch],
        },
        '2015-11-24 21:00:00' => {combination => 0},
        '2015-11-24 23:00:00' => {combination => 0},
        # Friday
        '2015-11-27 18:00:00' => {combination => 0},
        '2015-11-27 19:00:00' => {combination => 0},
    );

    my @e_offerings =
        grep { $_->{expiry_type} eq 'intraday' and $_->{contract_type} eq 'CALLE' } BOM::Product::Contract::Finder::Japan::get_offerings('frxEURUSD');
    my $ex = create_underlying('frxEURUSD')->calendar;
    foreach my $date (keys %expected_eur_intraday_trading_period) {
        my $now              = Date::Utility->new($date);
        my @eurusd_offerings = BOM::Product::Contract::Finder::Japan::_predefined_trading_period({
            offerings => \@e_offerings,
            calendar  => $ex,
            date      => $now,
            symbol    => 'frxEURUSD',
        });

        my @got_date_start  = map { $eurusd_offerings[$_]{trading_period}{date_start}{epoch} } keys @eurusd_offerings;
        my @got_date_expiry = map { $eurusd_offerings[$_]{trading_period}{date_expiry}{epoch} } keys @eurusd_offerings;

        is(
            scalar @eurusd_offerings,
            $expected_eur_intraday_trading_period{$date}{combination},
            "Matching expected intraday combination on EURUSD for $date"
        );

        if (scalar @eurusd_offerings > 1) {
            cmp_deeply(\@got_date_start, $expected_eur_intraday_trading_period{$date}{date_start}, "Expected date_start for $date");

            cmp_deeply(\@got_date_expiry, $expected_eur_intraday_trading_period{$date}{date_expiry}, "Expected date_expiry for $date");
        }

    }

};
subtest "predefined barriers" => sub {
    my %expected_barriers = (
        call_intraday => {
            available_barriers => [1.15015, 1.15207, 1.15303, 1.15399, 1.15495, 1.15591, 1.15687, 1.15783, 1.15879, 1.15975, 1.16167],
            barrier            => 1.15207,
            expired_barriers   => [],
        },
        onetouch_daily => {
            available_barriers => [1.13815, 1.14407, 1.14703, 1.14999, 1.15295, 1.15591, 1.15887, 1.16183, 1.16479, 1.16775, 1.17367],
            barrier            => 1.15141,
            expired_barriers   => [1.15295],
        },

        range_daily => {
            available_barriers => [[1.15295, 1.15887], [1.14999, 1.16183], [1.14703, 1.16479], [1.14407, 1.16775]],
            expired_barriers => [[1.15295, 1.15887]],
        },
        expiryrange_daily => {
            available_barriers => [
                [1.15295, 1.15887],
                [1.14999, 1.15591],
                [1.15591, 1.16183],
                [1.14703, 1.15295],
                [1.15887, 1.16479],
                [1.14407, 1.14999],
                [1.16183, 1.16775],
                [1.13815, 1.14703],
                [1.16479, 1.17367]
            ],
            expired_barriers => [],
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
        barriers         => 1,
        barrier_category => 'euro_non_atm',
    };
    my $underlying = create_underlying('frxEURUSD');
    my $now        = Date::Utility->new('2015-08-24 00:10:00');
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'frxEURUSD',
            epoch      => Date::Utility->new($_)->epoch,
            quote      => 1.15591,
        }) for ("2015-08-24 00:00:00");

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'frxEURUSD',
            epoch      => Date::Utility->new($_)->epoch,
            quote      => 1.1521,
        }) for ("2015-08-24 00:10:00");

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
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
    cmp_bag($contract->{available_barriers}, $expected_barriers{call_intraday}{available_barriers}, "Expected available barriers for intraday call");

    cmp_bag($contract->{expired_barriers}, $expected_barriers{call_intraday}{expired_barriers}, "Expected expired barriers for intraday call");
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
    cmp_deeply(
        $contract_2->{expired_barriers}[$_],
        $expected_barriers{range_daily}{expired_barriers}[$_],
        "Expected expired barriers for daily range"
    ) for keys @{$expected_barriers{range_daily}{expired_barriers}};

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
    cmp_deeply(
        $contract_3->{expired_barriers},
        $expected_barriers{expiryrange_daily}{expired_barriers},
        "Expected expired barriers for daily expiry range"
    );

    my $contract_4 = {
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
        barriers          => 1,
        barrier_category  => 'american',
        contract_category => 'onetouch',
    };
    BOM::Product::Contract::Finder::Japan::_set_predefined_barriers({
        underlying   => $underlying,
        contract     => $contract_4,
        current_tick => $underlying->tick_at($now),
        date         => $now
    });
    cmp_bag(
        $contract_4->{available_barriers},
        $expected_barriers{onetouch_daily}{available_barriers},
        "Expected available barriers for daily onetouch"
    );
    cmp_bag($contract_4->{expired_barriers}, $expected_barriers{onetouch_daily}{expired_barriers}, "Expected expired barriers for daily onetouch");

    my %expected_barriers_2 = (
        onetouch_daily => {
            available_barriers => [1.13815, 1.14407, 1.14703, 1.14999, 1.15295, 1.15591, 1.15887, 1.16183, 1.16479, 1.16775, 1.17367],
            barrier            => 1.15141,
            expired_barriers   => [1.15295],
        },

        range_daily => {
            available_barriers => [[1.15295, 1.15887], [1.14999, 1.16183], [1.14703, 1.16479], [1.14407, 1.16775]],
            expired_barriers => [[1.15295, 1.15887]],
        },

    );
    my $new_date = Date::Utility->new("2015-08-24 00:20:00");
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'frxEURUSD',
            epoch      => $_->epoch,
            quote      => 1.151,
        }) for ($new_date);

    BOM::Product::Contract::Finder::Japan::_set_predefined_barriers({
        underlying   => $underlying,
        contract     => $contract_4,
        current_tick => $underlying->tick_at($new_date),
        date         => $new_date,
    });
    cmp_bag(
        $contract_4->{available_barriers},
        $expected_barriers_2{onetouch_daily}{available_barriers},
        "Expected available barriers for daily onetouch after 10 min"
    );
    cmp_bag(
        $contract_4->{expired_barriers},
        $expected_barriers_2{onetouch_daily}{expired_barriers},
        "Expected expired barriers for daily onetouch after 10 min"
    );

    BOM::Product::Contract::Finder::Japan::_set_predefined_barriers({
        underlying   => $underlying,
        contract     => $contract_2,
        current_tick => $underlying->tick_at($new_date),
        date         => $new_date
    });
    cmp_deeply(
        $contract_2->{available_barriers}[$_],
        $expected_barriers_2{range_daily}{available_barriers}[$_],
        "Expected available barriers for daily range after 10min"
    ) for keys @{$expected_barriers_2{range_daily}{available_barriers}};
    cmp_deeply(
        $contract_2->{expired_barriers}[$_],
        $expected_barriers_2{range_daily}{expired_barriers}[$_],
        "Expected expired barriers for daily range after 10 min"
    ) for keys @{$expected_barriers_2{range_daily}{expired_barriers}};

};

