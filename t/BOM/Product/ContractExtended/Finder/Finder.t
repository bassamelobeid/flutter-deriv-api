#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 5;
use Test::Warnings;
use Test::Exception;
use Test::Deep;
use Test::MockModule;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Product::ContractFinder;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Date::Utility;
use Test::MockModule;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'partial_trading',
    {
        type          => 'early_closes',
        recorded_date => Date::Utility->new('2015-01-01'),
        # dummy early close
        calendar => {
            '25-Nov-2015' => {
                '18h00m' => ['FOREX'],
            },
        },
    });

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
            "2015-01-01",          "2015-07-01",          "2015-08-03",          "2015-08-17",          "2015-08-21",
            "2015-08-21 00:45:00", "2015-08-21 03:45:00", "2015-08-21 04:45:00", "2015-08-21 05:30:00", "2015-08-24 00:00:00",
            "2015-08-31",          "2015-08-31 00:00:01", "2015-09-04 16:30:00", time
            );
        BOM::Test::Data::Utility::UnitTestMarketData::create_trading_periods($symbol, $now);
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
        # svg, japan
        'frxUSDJPY-svg-jp' => {
            contract_count => {
                callputequal => 2,
                callput      => 2
            },
            hit_count => 4,
        },
        # svg, canada
        'frxUSDJPY-svg-ca' => {
            hit_count => 0,
        },
        # svg, china
        'frxUSDJPY-svg-cn' => {
            hit_count => 0,
        },
        # svg, no country
        'frxUSDJPY-svg' => {
            contract_count => {
                callputequal => 2,
                callput      => 2
            },
            hit_count => 4,
        },
        # malta, austria
        'frxUSDJPY-malta-at'     => {hit_count => 0},
        'frxAUDCAD-svg-id' => {hit_count => 0},
    );
    foreach my $key (keys %expected) {
        my ($u, $landing_company, $country_code) = split '-', $key;
        my $f = BOM::Product::ContractFinder->new(for_date => $now)->multi_barrier_contracts_for({
            symbol          => $u,
            landing_company => $landing_company,
            country_code    => $country_code,
        });
        my %got;
        $got{$_->{contract_category}}++ for (@{$f->{available}});
        is($f->{hit_count}, $expected{$key}{hit_count}, "Expected total contract for $key");
        cmp_ok $got{$_}, '==', $expected{$key}{contract_count}{$_}, "Expected total contract  for $key on this $_ type"
            for (keys %{$expected{$key}{contract_count}});
    }
};

subtest "predefined trading_period" => sub {
    my %expected_count = (
        offering_with_predefined_trading_period => 4,
        # call_daily, range_intraday, and range_daily were used in Japan but are no longer used
        trading_period => {
            call_intraday  => 2,
            call_daily     => 0,
            range_intraday => 0,
            range_daily    => 0,
        });

    my %expected_trading_period = (
        call_intraday => {
            duration => ['2h', '6h'],
            date_expiry => [map { Date::Utility->new($_)->epoch } ('2015-09-04 18:15:00', '2015-09-04 18:15:00',)],
            date_start  => [map { Date::Utility->new($_)->epoch } ('2015-09-04 16:15:00', '2015-09-04 12:15:00',)],
        });

    my $now = Date::Utility->new('2015-09-04 17:00:00');
    my $underlying = create_underlying('frxUSDJPY', $now);
    BOM::Test::Data::Utility::UnitTestMarketData::create_trading_periods($underlying->symbol, $now);
    my @new = @{BOM::Product::ContractFinder->new(for_date => $now)->multi_barrier_contracts_for({symbol => $underlying->symbol})->{available}};

    my %got = map { $_ => [] } keys %{$expected_count{trading_period}};
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

my $mock = Test::MockModule->new('Quant::Framework::Underlying');
$mock->mock('get_high_low_for_period', sub { return {high => 100.01, low => 99.01} });

subtest "check_intraday trading_period_JPY" => sub {
    my %expected_intraday_trading_period = (
        # sunday
        '2015-11-22 23:59:00' => {combination => 0},
        # monday
        '2015-11-23 00:15:00' => {
            combination => 2,                                                                                                   # one call and one put
            date_start  => [Date::Utility->new('2015-11-23 00:15:00')->epoch, Date::Utility->new('2015-11-23 00:15:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-23 02:15:00')->epoch, Date::Utility->new('2015-11-23 06:15:00')->epoch],
        },
        '2015-11-23 01:15:00' => {
            combination => 2,
            date_start  => [Date::Utility->new('2015-11-23 00:15:00')->epoch, Date::Utility->new('2015-11-23 00:15:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-23 02:15:00')->epoch, Date::Utility->new('2015-11-23 06:15:00')->epoch],

        },
        '2015-11-23 13:15:00' => {
            combination => 2,
            date_start  => [Date::Utility->new('2015-11-23 12:15:00')->epoch, Date::Utility->new('2015-11-23 12:15:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-23 14:15:00')->epoch, Date::Utility->new('2015-11-23 18:15:00')->epoch],

        },
        '2015-11-23 14:15:00' => {
            combination => 2,
            date_start  => [Date::Utility->new('2015-11-23 14:15:00')->epoch, Date::Utility->new('2015-11-23 12:15:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-23 16:15:00')->epoch, Date::Utility->new('2015-11-23 18:15:00')->epoch],
        },

        '2015-11-23 17:15:00' => {
            combination => 2,
            date_start  => [Date::Utility->new('2015-11-23 16:15:00')->epoch, Date::Utility->new('2015-11-23 12:15:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-23 18:15:00')->epoch, Date::Utility->new('2015-11-23 18:15:00')->epoch],

        },

        '2015-11-23 18:15:00' => {combination => 0},
        '2015-11-23 19:00:00' => {combination => 0},
        '2015-11-23 20:00:00' => {combination => 0},
        '2015-11-23 21:00:00' => {combination => 0},
        '2015-11-23 22:00:00' => {combination => 0},
    );

    foreach my $date (sort keys %expected_intraday_trading_period) {
        my $now = Date::Utility->new($date);
        BOM::Test::Data::Utility::UnitTestMarketData::create_trading_periods('frxUSDJPY', $now);
        my @intraday_offerings = grep { $_->{expiry_type} eq 'intraday' and $_->{contract_type} eq 'CALLE' }
            @{BOM::Product::ContractFinder->new(for_date => $now)->multi_barrier_contracts_for({symbol => 'frxUSDJPY'})->{available}};
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
        #sunday
        '2015-11-22 23:59:00' => {combination => 0},
        # monday
        '2015-11-23 00:15:00' => {
            combination => 2,
            date_start  => [Date::Utility->new('2015-11-23 00:15:00')->epoch, Date::Utility->new('2015-11-23 00:15:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-23 02:15:00')->epoch, Date::Utility->new('2015-11-23 06:15:00')->epoch],
        },
        '2015-11-23 18:15:00' => {combination => 0},
        '2015-11-23 22:15:00' => {combination => 0},

        # tues
        '2015-11-24 00:15:00' => {
            combination => 2,
            date_start  => [Date::Utility->new('2015-11-24 00:15:00')->epoch, Date::Utility->new('2015-11-24 00:15:00')->epoch],
            date_expiry => [Date::Utility->new('2015-11-24 02:15:00')->epoch, Date::Utility->new('2015-11-24 06:15:00')->epoch],
        },
        '2015-11-24 21:00:00' => {combination => 0},
        '2015-11-24 23:00:00' => {combination => 0},
        # Friday
        '2015-11-27 18:15:00' => {combination => 0},
        '2015-11-27 19:00:00' => {combination => 0},
    );

    foreach my $date (keys %expected_eur_intraday_trading_period) {
        my $now = Date::Utility->new($date);
        BOM::Test::Data::Utility::UnitTestMarketData::create_trading_periods('frxEURUSD', $now);
        my @eurusd_offerings = grep { $_->{expiry_type} eq 'intraday' and $_->{contract_type} eq 'CALLE' }
            @{BOM::Product::ContractFinder->new(for_date => $now)->multi_barrier_contracts_for({symbol => 'frxEURUSD'})->{available}};
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
