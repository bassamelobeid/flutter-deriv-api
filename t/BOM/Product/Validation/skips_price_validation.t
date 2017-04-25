#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::FailWarnings;
use LandingCompany::Offerings qw(reinitialise_offerings);

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Market::DataDecimate;
use Date::Utility;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Cache::RedisDB;

Cache::RedisDB->flushall;
reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);
initialize_realtime_ticks_db();

note('mocking ticks to prevent warnings.');
my $mocked = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked->mock(
    'decimate_cache_get',
    sub {
        [map { {quote => 100, symbol => 'frxUSDJPY', epoch => $_} } (0 .. 10)];
    });

note('sets time to 21:59:59, which has a payout cap at 200 for forex.');
my $now = Date::Utility->new('2016-09-19 21:59:59');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(USD JPY JPY-USD);

my $fake = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch
});

my $bet_params = {
    bet_type     => 'CALL',
    underlying   => 'frxUSDJPY',
    q_rate       => 0,
    r_rate       => 0,
    barrier      => 'S0P',
    currency     => 'USD',
    payout       => 1000,
    current_tick => $fake,
    date_pricing => $now,
    date_start   => $now,
    duration     => '2m',
};

subtest 'skips price validation' => sub {
    $bet_params->{disable_trading_at_quiet_period} = 0;
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->payout, 1000, 'payout is 1000';
    ok !$c->skips_price_validation, 'validate price';
    like($c->primary_validation_error->message, qr/payout amount outside acceptable range/, 'throws error');
    $bet_params->{skips_price_validation} = 1;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
};

done_testing();
