#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 4;
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
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('exchange',        {symbol => 'FOREX'});
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency',        {symbol => $_}) for qw(USD JPY AUD CAD EUR);
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency_config', {symbol => $_}) for qw(USD JPY AUD CAD EUR);
subtest "predefined contracts for symbol" => sub {
    my $now = Date::Utility->new('2015-08-21 05:30:00');
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
                touchnotouch => 10,
                staysinout   => 10,
                endsinout    => 10,
            },
            hit_count => 46,
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
        offering_with_predefined_trading_period => 44,
        trading_period                          => {
            call_intraday => 3,
            call_daily    => 5,
            range_daily   => 5,
        });

    my %expected_trading_period = (
        call_intraday => {
            duration    => ['0d', '1d', '26d', '26d', '117d','2h', '5h', '5h'],
            date_expiry => [
                map { Date::Utility->new($_)->epoch } (
                    '2015-09-04 21:00:00',
                    '2015-09-07 23:59:59',
                    '2015-09-30 23:59:59',
                    '2015-09-30 23:59:59',
                    '2015-12-31 23:59:59',
                    '2015-09-04 18:00:00',
                    '2015-09-04 18:00:00',
                    '2015-09-04 22:00:00',
                )
            ],
            date_start => [
                map { Date::Utility->new($_)->epoch } (
                    '2015-09-04 00:00:00',
                    '2015-09-04 00:00:00',
                    '2015-09-04 00:00:00',
                    '2015-09-04 00:00:00',
                    '2015-09-04 00:00:00',
                    '2015-09-04 15:45:00',
                    '2015-09-04 12:45:00',
                    '2015-09-04 16:45:00',
                )
            ],
        },
        range_daily => {
            duration    => ['0d', '1d', '26d', '117d'],
            date_expiry => [
                map { Date::Utility->new($_)->epoch } (
                    '2015-09-04 21:00:00',
                    '2015-09-07 23:59:59',
                    '2015-09-30 23:59:59',
                    '2015-09-30 23:59:59',
                    '2015-12-31 23:59:59',
                )
            ],
            date_start => [
                map { Date::Utility->new($_)->epoch } (
                    '2015-09-04 00:00:00',
                    '2015-09-04 00:00:00',
                    '2015-09-04 00:00:00',
                    '2015-09-04 00:00:00',
                    '2015-09-04 00:00:00',
                )
            ],
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
subtest "predefined barriers" => sub {

    my %expected_barriers = (
        call_intraday => {
            available_barriers => [
                1.15581, 1.15601, 1.15571, 1.15611, 1.15561, 1.15621, 1.15551, 1.15631, 1.15541, 1.15641, 1.15521, 1.15661,
                1.15501, 1.15681, 1.15451, 1.15731, 1.15351, 1.15831, 1.15151, 1.16031, 1.15591
            ],
            barrier => 1.15591,
        },
        range_daily => {
            available_barriers => [
                [1.15559, 1.15527, 1.15495, 1.15463, 1.15431, 1.15367, 1.15303, 1.15143, 1.14823, 1.14183],
                [1.15623, 1.15655, 1.15687, 1.15719, 1.15751, 1.15815, 1.15879, 1.16039, 1.16359, 1.16999]
            ],
            high_barrier => 1.15623,
            low_barrier  => 1.15559,
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
            duration => '5h',
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
    cmp_deeply(
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
        barriers => 2,
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
    is($contract_2->{high_barrier}, $expected_barriers{range_daily}{high_barrier}, "Expected high barrier for daily range");
    is($contract_2->{low_barrier},  $expected_barriers{range_daily}{low_barrier},  "Expected low barrier for daily range");

};
