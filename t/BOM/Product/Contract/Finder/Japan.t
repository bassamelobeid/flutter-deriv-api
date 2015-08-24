#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::Exception;
use Test::NoWarnings;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use Test::MockTime;
use BOM::Product::Contract::Finder::Japan qw(predefined_contracts_for_symbol);
use BOM::Product::Offerings qw(get_offerings_flyby);
use BOM::Market::Underlying;
use Date::Utility;
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('exchange',        {symbol => 'FOREX'});
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency',        {symbol => $_}) for qw(USD JPY AUD CAD);
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency_config', {symbol => $_}) for qw(USD JPY AUD CAD);
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
                callput      => 32,
                touchnotouch => 32,
                staysinout   => 12,
                endsinout    => 12,
            },
            hit_count => 88,
        },
        frxAUDCAD => {hit_count => 0},
    );
    foreach my $u (keys %expected) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => $u,
            epoch      => $now->epoch,
            quote      => 100
        });
        my $f = predefined_contracts_for_symbol({
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
        offering_with_predefined_trading_period => 100,
        trading_period                          => {
            call_intraday => 11,
            call_daily    => 7,
            range_daily   => 7,
        });

    my %expected_trading_period = (
        call_intraday => {
            duration => ['2h', '3h', '4h', '5h', '1d', '4d', '7d', '32d', '60d', '180d', '365d'],
            date_expiry =>
                [1438826400, 1438830000, 1438833600, 1438837200, 1438981200, 1439251199, 1439510399, 1441670399, 1444089599, 1454457599, 1470430800],
            date_start =>
                [1438819200, 1438819200, 1438819200, 1438819200, 1438819200, 1438819200, 1438819200, 1438819200, 1438819200, 1438819200, 1438819200],
        },
        range_daily => {
            duration    => ['1d',       '4d',       '7d',       '32d',      '60d',      '180d',     '365d'],
            date_expiry => [1438981200, 1439251199, 1439510399, 1441670399, 1444089599, 1454457599, 1470430800],
            date_start  => [1438819200, 1438819200, 1438819200, 1438819200, 1438819200, 1438819200, 1438819200],
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
    my $now      = Date::Utility->new('2015-08-06 00:00:00');

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

    foreach my $bet_type (keys %expected_trading_period ) {

        my @got_duration = map { $got{$bet_type}[$_]{duration} } keys $got{$bet_type};
        is_deeply(\@got_duration, $expected_trading_period{$bet_type}{duration}, "Expected duration for $bet_type");
        my @got_date_start = map { $got{$bet_type}[$_]{date_start}{epoch} } keys $got{$bet_type};
        is_deeply(\@got_date_start, $expected_trading_period{$bet_type}{date_start}, "Expected date_start for $bet_type");

        my @got_date_expiry = map { $got{$bet_type}[$_]{date_expiry}{epoch} } keys $got{$bet_type};
        is_deeply(\@got_date_expiry, $expected_trading_period{$bet_type}{date_expiry}, "Expected date_expiry for $bet_type");
    }
};
