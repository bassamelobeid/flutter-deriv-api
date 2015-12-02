#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 33;
use Test::NoWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Market::Data::Tick;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use Date::Utility;

my $now = Date::Utility->new()->truncate_to_day->plus_time_interval('1h');
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol         => 'RANDOM',
        trading_days   => 'everyday',
        holidays       => {},
        "market_times" => {
            "early_closes" => {

            },
            "standard" => {
                "daily_close"      => "23h59m59s",
                "daily_settlement" => "23h59m59s",
                "daily_open"       => "0s"
            },
            "partial_trading" => {

            }
        },
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol         => 'RANDOM_NOCTURNE',
        trading_days   => 'everyday',
        holidays       => {},
        "market_times" => {
            "early_closes" => {

            },
            "standard" => {
                "daily_close"      => "11h59m59s",
                "daily_settlement" => "11h59m59s",
                "daily_open"       => "-12h"
            },
            "partial_trading" => {

            }
        },
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_phased',
    {
        symbol        => $_,
        recorded_date => $now,
    }) for qw(RDMOON RDSUN RDMARS RDVENUS);
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('index', {symbol => $_}) for qw(RDMARS RDSUN RDMOON RDVENUS);
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency', {symbol => 'USD'});

my @test_cases = ({
        underlying => 'RDSUN',
        date_start => [
            $now,                                             $now->truncate_to_day->minus_time_interval('1h'),
            $now->truncate_to_day->plus_time_interval('59s'), $now->truncate_to_day->plus_time_interval('23h59m1s')
        ],
    },
    {
        underlying => 'RDMOON',
        date_start => [
            $now,                                             $now->truncate_to_day->minus_time_interval('1h'),
            $now->truncate_to_day->plus_time_interval('59s'), $now->truncate_to_day->plus_time_interval('23h59m1s')
        ],
    },
    {
        underlying => 'RDMARS',
        date_start => [
            $now,                                                $now->truncate_to_day->plus_time_interval('11h'),
            $now->truncate_to_day->plus_time_interval('12h59s'), $now->truncate_to_day->plus_time_interval('11h59m1s')
        ],
    },
    {
        underlying => 'RDVENUS',
        date_start => [
            $now,                                                $now->truncate_to_day->plus_time_interval('11h'),
            $now->truncate_to_day->plus_time_interval('12h59s'), $now->truncate_to_day->plus_time_interval('11h59m1s')
        ],
    },
);
foreach my $t (@test_cases) {
    my $u        = $t->{underlying};
    my @duration = ('24h', '1h1s', '1h', '15s');
    my $count    = 0;
    my @error    = (
        qr/expire on the same trading day/,
        qr/expire on the same trading day/,
        qr/Trading is available after the first 1 minute of the session/,
        qr/Contract may not expire within the last 1 minute of trading/
    );
    foreach my $ds (@{$t->{date_start}}) {
        my $tick = BOM::Market::Data::Tick->new({
            symbol => $u,
            quote  => 100,
            epoch  => $ds->epoch,
        });
        my $pp = {
            bet_type     => 'CALL',
            underlying   => $u,
            barrier      => 'S0P',
            date_start   => $ds,
            date_pricing => $ds,
            currency     => 'USD',
            payout       => 100,
            duration     => $duration[$count],
            current_tick => $tick,
        };
        my $c = produce_contract($pp);
        ok !$c->is_valid_to_buy, 'not valid to buy';
        like $c->primary_validation_error->message_to_client, $error[$count], "underlying $u, error is as expected [$error[$count]]";
        $count++;
    }
}
