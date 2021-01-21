#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Warnings;
use Test::Exception;
use Test::Fatal;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Market::DataDecimate;
use Date::Utility;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Cache::RedisDB;

Cache::RedisDB->flushall;
initialize_realtime_ticks_db();

note('mocking ticks to prevent warnings.');
my $mocked = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked->mock(
    'get',
    sub {
        [map { {epoch => $_, decimate_epoch => $_, quote => 100 + 0.005 * $_} } (0 .. 80)];
    });
$mocked->mock(
    'decimate_cache_get',
    sub {
        [map { {quote => 100, symbol => 'R_100', epoch => $_, decimate_epoch => $_} } (0 .. 10)];
    });

note('sets time to 21:59:59, which has a payout cap at 200 for forex.');
my $now = Date::Utility->new('2016-09-19 21:59:59');

my $fake = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_100',
    epoch      => $now->epoch
});

my $bet_params = {
    bet_type     => 'CALL',
    underlying   => 'R_100',
    q_rate       => 0,
    r_rate       => 0,
    barrier      => 'S0P',
    currency     => 'USD',
    payout       => 1000,
    current_tick => $fake,
    date_pricing => $now,
    date_start   => $now,
    duration     => '3m',
};

subtest 'skips minimum payout validation' => sub {
    $bet_params->{disable_trading_at_quiet_period} = 0;
    $bet_params->{payout}                          = 0.00001;

    my $error = exception { produce_contract($bet_params); };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->error_code, 'InvalidMinPayout', 'correct error code';

    $bet_params->{skip_contract_input_validation} = 1;
    my $c = produce_contract($bet_params);
    isa_ok $c->pricing_engine, 'Pricing::Engine::BlackScholes';
};

$bet_params = {
    bet_type     => 'LBFLOATCALL',
    underlying   => 'R_100',
    date_start   => $now,
    date_pricing => $now,
    duration     => '1h',
    currency     => 'USD',
    multiplier   => '1',
};

subtest 'skips minimum multiplier validation' => sub {
    $bet_params->{disable_trading_at_quiet_period} = 0;
    $bet_params->{multiplier}                      = 0.00001;

    my $error = exception { produce_contract($bet_params); };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->error_code, 'MinimumMultiplier', 'correct error code';

    $bet_params->{skip_contract_input_validation} = 1;
    my $c = produce_contract($bet_params);
    isa_ok $c->pricing_engine, 'Pricing::Engine::Lookback';

};

done_testing();
