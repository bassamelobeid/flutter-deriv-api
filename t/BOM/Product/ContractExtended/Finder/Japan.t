#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 4;
use Test::Exception;
use Test::Deep;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Product::Contract::Finder::Japan qw(available_contracts_for_symbol);
use BOM::Product::Contract::PredefinedParameters qw(generate_trading_periods);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Date::Utility;

BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD JPY AUD CAD EUR);
subtest "predefined contracts for symbol" => sub {
   my $now = Date::Utility->new('2015-08-21 05:30:00');
   foreach my $symbol (qw(frxUSDJPY frxAUDUSD frxEURUSD)) {
       BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
               underlying => $symbol,
               epoch      => Date::Utility->new($_)->epoch,
               quote      => 100,
           })
           for (
           "2015-01-01",          "2015-07-01",          "2015-08-03",          "2015-08-17", "2015-08-21",
           "2015-08-21 00:45:00", "2015-08-21 03:45:00", "2015-08-21 04:45:00", "2015-08-21 05:30:00", "2015-08-24 00:00:00",  "2015-08-31", "2015-08-31 00:00:01", "2015-09-04 16:30:00", time
           );
       generate_trading_periods($symbol, $now);
   }

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

    my @offerings = BOM::Product::Contract::PredefinedParameters::_get_offerings('frxUSDJPY');
    is(scalar(@offerings), $expected_count{'offering'}, 'Expected total contract before included predefined trading period');
    my $now      = Date::Utility->new('2015-09-04 17:00:00');
    my $underlying = create_underlying('frxUSDJPY', $now);
    generate_trading_periods($underlying->symbol, $now);
    my @new = @{BOM::Product::Contract::PredefinedParameters::_apply_predefined_parameters($now, $underlying, \@offerings)};

    my %got;
    foreach my $d (@new) {
        $d->{contract_type} eq 'CALLE'
            and $d->{expiry_type} eq 'intraday' ? push @{$got{call_intraday}}, $d->{trading_period} : push @{$got{call_daily}},
            $d->{trading_period};
        $d->{contract_type} eq 'RANGE'
            and $d->{expiry_type} eq 'intraday' ? push @{$got{range_intraday}}, $d->{trading_period} : push @{$got{range_daily}},
            $d->{trading_period};
    }
    is(
        scalar(keys @new),
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

    my @i_offerings = grep { $_->{expiry_type} eq 'intraday' and  $_->{contract_type} eq 'CALLE'} BOM::Product::Contract::PredefinedParameters::_get_offerings('frxUSDJPY');
    foreach my $date (keys %expected_intraday_trading_period) {
        my $now                = Date::Utility->new($date);
        my $ex = create_underlying('frxUSDJPY', $now);
        generate_trading_periods($ex->symbol, $now);
        my @intraday_offerings = @{BOM::Product::Contract::PredefinedParameters::_apply_predefined_parameters($now, $ex, \@i_offerings)};
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

    my @e_offerings = grep { $_->{expiry_type} eq 'intraday' and  $_->{contract_type} eq 'CALLE'} BOM::Product::Contract::PredefinedParameters::_get_offerings('frxEURUSD');
    foreach my $date (keys %expected_eur_intraday_trading_period) {
        my $now              = Date::Utility->new($date);
        my $ex = create_underlying('frxEURUSD', $now);
        generate_trading_periods($ex->symbol, $now);
        my @eurusd_offerings = @{BOM::Product::Contract::PredefinedParameters::_apply_predefined_parameters($now, $ex, \@e_offerings)};
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
