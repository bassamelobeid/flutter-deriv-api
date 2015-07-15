#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::FailWarnings;
use Test::Exception;
use Test::MockModule;

use BOM::Product::Pricing::Engine::TickExpiry;
use BOM::Market::Data::Tick;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);

my $now = Date::Utility->new('24-Dec-2014');

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('exchange');

# Extra currencies are to cover WLDUSD components
foreach my $needed_currency (qw(USD GBP JPY AUD EUR)) {
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency', {symbol => $needed_currency});
}

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxGBPUSD',
        recorded_date => $now,
    });

my @ticks = map { BOM::Market::Data::Tick->new({symbol => 'frxGBPUSD', epoch => $now->epoch + $_, quote => 100}) } (1 .. 20);
my $mocked = Test::MockModule->new('BOM::Product::Pricing::Engine::TickExpiry');
$mocked->mock('_latest_ticks', sub { \@ticks });
subtest 'tick expiry fx CALL' => sub {
    my $c = produce_contract({
        bet_type   => 'FLASHU',
        underlying => 'frxGBPUSD',
        date_start => $now,
        duration   => '5t',
        currency   => 'USD',
        payout     => 10,
        barrier    => 'S0P',
    });
    is $c->pricing_engine->risk_markup->amount,       -0.1,  'tie adjustment floored at -0.1';
    is $c->pricing_engine->probability->amount,       0.5,   'theo prob floored at 0.5 for CALL';
    is $c->pricing_engine->commission_markup->amount, 0.025, 'commission is 2.5%';
};

subtest 'tick expiry fx PUT' => sub {
    my $c = produce_contract({
        bet_type   => 'FLASHD',
        underlying => 'frxGBPUSD',
        date_start => $now,
        duration   => '5t',
        currency   => 'USD',
        payout     => 10,
        barrier    => 'S0P',
    });
    is $c->pricing_engine->risk_markup->amount,       -0.1,  'tie adjustment floored at -0.1';
    is $c->pricing_engine->probability->amount,       0.5,   'theo prob floored at 0.5 for PUT';
    is $c->pricing_engine->commission_markup->amount, 0.025, 'commission is 2.5%';
};

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_flat',
    {
        symbol        => 'WLDUSD',
        recorded_date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('index', {symbol => 'WLDUSD'});

@ticks = map { BOM::Market::Data::Tick->new({symbol => 'frxGBPUSD', epoch => $now->epoch + $_, quote => 100 + rand(10)}) } (1 .. 20);
$mocked->mock('_latest_ticks', sub { \@ticks });

my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'WLDUSD',
        epoch      => '2014-12-24 00:00:00',
    },
);

subtest 'tick expiry smart fx' => sub {
    my $c = produce_contract({
        bet_type   => 'FLASHU',
        underlying => 'WLDUSD',
        date_start => $now,
        duration   => '5t',
        currency   => 'USD',
        payout     => 10,
        barrier    => 'S0P',
    });
    cmp_ok $c->pricing_engine->risk_markup->amount, ">",  -0.1, 'tie adjustment floored at -0.1';
    cmp_ok $c->pricing_engine->probability->amount, ">=", 0.5,  'theo prob floored at 0.5';
    is $c->pricing_engine->commission_markup->amount, 0.02, 'commission is 2%';
};

