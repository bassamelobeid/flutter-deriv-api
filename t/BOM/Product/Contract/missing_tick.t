#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 6;
use Test::NoWarnings;
use Test::Exception;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'USD',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'R_50',
        date   => Date::Utility->new,
    });
my $now       = Date::Utility->new();
my $tick_date = $now->plus_time_interval('5m');
my $exit_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_50',
    epoch      => $now->plus_time_interval('1m')->epoch,
    quote      => 101,
    bid        => 100,
    ask        => 100,
});

my $entry_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_50',
    epoch      => $tick_date->epoch,
    quote      => 100,
    bid        => 100,
    ask        => 100,
});

lives_ok {
    my $c = produce_contract({
        bet_type     => 'NOTOUCH',
        underlying   => 'R_50',
        date_start   => $now,
        duration     => '1m',
        date_pricing => $tick_date->plus_time_interval('1m'),
        currency     => 'USD',
        payout       => 10,
        barrier      => 'S10P',
        entry_tick   => $entry_tick,
        exit_tick    => $exit_tick,
    });
    ok $c->is_expired, 'contract expired';
    ok !$c->is_valid_to_sell,         'expired but not valid to sell';
    ok !$c->may_settle_automatically, 'expired but could not settle automatically';
    ok $c->missing_market_dat, 'missing market data';
    like $c->primary_validation_error->message, qr/No tick received/, 'right error message thrown';
}
'test missing tick settlement';
