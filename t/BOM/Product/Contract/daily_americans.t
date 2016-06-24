#!/usr/bin/perl

use strict;
use warnings;

use Test::Most tests => 1;
use Test::Exception;
use Test::FailWarnings;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);

initialize_realtime_ticks_db();
my $ul   = BOM::Market::Underlying->new('DJI');
my $when = Date::Utility->new('2015-11-08 16:00:00');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'USD',
        date   => Date::Utility->new
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => $ul->symbol,
        recorded_date => $when,
    });

my $entry_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => $ul->symbol,
    epoch      => $when->epoch + 1,
    quote      => 10_000,
});
BOM::Test::Data::Utility::FeedTestDatabase::create_ohlc_daily({
    underlying => 'DJI',
    epoch      => $when->truncate_to_day->plus_time_interval('1d')->epoch,
    open       => 10_000,
    high       => 12_000,
    low        => 10_000,
    close      => 10_000,
});

# OHLC with hit data

subtest 'resolve onetouch correctly with no ticks, but OHLC' => sub {

    my $args = {
        bet_type   => 'ONETOUCH',
        underlying => $ul,
        date_start => $when,
        duration   => '1d',
        entry_tick => $entry_tick,
        currency   => 'USD',
        payout     => 10,
        barrier    => 11_000,
    };
    my $c = produce_contract($args);
    cmp_ok $c->entry_tick->quote,    '==', 10_000, 'correct entry tick';
    cmp_ok $c->barrier->as_absolute, '==', 11_000, 'correct barrier';
    ok $c->is_expired, 'contract is expired';
    cmp_ok $c->value, '==', $c->payout, 'hit via OHLC - full payout';
};

1;
