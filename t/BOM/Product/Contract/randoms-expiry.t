#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 33;
use Test::NoWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Market::Data::Tick;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use Date::Utility;

my $now = Date::Utility->new()->truncate_to_day->plus_time_interval('1h');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('index', {symbol => $_}) for qw(RDMARS RDSUN RDMOON RDVENUS);

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
    my $type = ($u eq 'RDMARS' or $u eq 'RDVENUS') ? 'afternoon' : 'midnight';
    my @duration = ('24h', '1h1s', '1h', '15s');
    my $count    = 0;
    my %reset_type = (
        afternoon => [
            qr/expire on the same trading day/,
            qr/expire on the same trading day/,
            qr/Trading is not available from 12:00:00 to 12:01:00/,
            qr/Contract may not expire between 11:59:00 and 11:59:59/
        ],
        midnight => [
            qr/expire on the same trading day/,
            qr/expire on the same trading day/,
            qr/Trading is not available from 00:00:00 to 00:01:00/,
            qr/Contract may not expire between 23:59:00 and 23:59:59/
        ],
    );
    foreach my $ds (@{$t->{date_start}}) {
        my $tick = BOM::Market::Data::Tick->new({
            symbol => $u,
            quote  => 100,
            epoch  => $ds->epoch,
        });
        BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
            'currency',
            {
                symbol        => 'USD',
                recorded_date => $ds,
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
        like $c->primary_validation_error->message_to_client, $reset_type{$type}[$count], "underlying $u, error is as expected [$reset_type{$type}[$count]]";
        $count++;
    }
}
