#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::FailWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
#use BOM::Market::AggTicks;
use Data::Resample::ResampleCache;
use Data::Resample::TicksCache;
use Date::Utility;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Cache::RedisDB;
Cache::RedisDB->flushall;
initialize_realtime_ticks_db();

my $now = Date::Utility->new('2016-09-19 19:59:59');
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
    underlying => 'frxAUDUSD',
    epoch      => $now->epoch
});
my $bet_params = {
    bet_type     => 'CALL',
    underlying   => 'frxUSDJPY',
    q_rate       => 0,
    r_rate       => 0,
    barrier      => 'S0P',
    currency     => 'USD',
    payout       => 10,
    current_tick => $fake,
    date_pricing => $now,
    date_start   => $now,
    duration     => '2m',
};

#my $mocked = Test::MockModule->new('BOM::Market::AggTicks');
#$mocked->mock(
#    'retrieve',
#    sub {
#        [map { {quote => 100, symbol => 'frxUSDJPY', epoch => $_} } (0 .. 10)];
#    });
my $mocked = Test::MockModule->new('Data::Resample::ResampleCache');
$mocked->mock(
    'resample_cache_get',
    sub {
        [map { {quote => 100, symbol => 'frxUSDJPY', epoch => $_} } (0 .. 10)];
    });

my $mocked2 = Test::MockModule->new('Data::Resample::TicksCache');
$mocked2->mock(
    'tick_cache_get',
    sub {
        [map { {quote => 100, symbol => 'frxUSDJPY', agg_epoch => $_, epoch => $_} } (0 .. 10)];
    });

subtest 'inefficient period' => sub {
    note('price at 2016-09-19 19:59:59');
    my $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{date_start} = $bet_params->{date_pricing} = $now->plus_time_interval('1s');
    note('price at 2016-09-19 20:00:00');
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy,       'valid to buy';
    ok $c->market_is_inefficient, 'market inefficient flag triggered';
    $bet_params->{underlying} = 'R_100';
    note('set underlying to R_100. Makes sure only forex is affected.');
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{underlying} = 'frxUSDJPY';
    $bet_params->{duration}   = '1d';
    note('set underlying to frxUSDJPY and duration to 1 day');
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';

    note('set duration to five ticks.');
    $bet_params->{duration} = '5t';
    #my $mock = Test::MockModule->new('BOM::Market::AggTicks');
    #$mock->mock(
    #    'retrieve',
    #    sub {
    #        my $dp = $bet_params->{date_pricing}->epoch;
    #        [map { {quote => 100 + rand(1), epoch => $_} } ($dp .. $dp + 19)];
    #    });
    my $mock = Test::MockModule->new('Data::Resample::ResampleCache');
    $mock->mock(
        'resample_cache_get',
        sub {
            my $dp = $bet_params->{date_pricing}->epoch;
            [map { {quote => 100 + rand(1), epoch => $_} } ($dp .. $dp + 19)];
        });

    my $mock2 = Test::MockModule->new('Data::Resample::TicksCache');
    $mock2->mock(
        'tick_cache_get',
        sub {
            my $dp = $bet_params->{date_pricing}->epoch;
            [map { {quote => 100 + rand(1), epoch => $_} } ($dp .. $dp + 19)];
        });

    $mock2->mock(
        'tick_cache_get_num_ticks',
        sub {
            my $dp = $bet_params->{date_pricing}->epoch;
            [map { {quote => 100 + rand(1), epoch => $_} } ($dp .. $dp + 19)];
        });
    
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy,       'valid to buy';
    ok $c->market_is_inefficient, 'market inefficient flag triggered for tick expiry';
};

subtest 'non dst' => sub {
    note('price at 2017-01-04 20:59:59');
    my $non_dst = Date::Utility->new('2017-01-04 20:59:59');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxUSDJPY',
            recorded_date => $non_dst
        });
    $bet_params->{current_tick} = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $non_dst->epoch
    });
    $bet_params->{date_start} = $bet_params->{date_pricing} = $non_dst;
    $bet_params->{duration} = '2m';
    my $c = produce_contract($bet_params);
    ok !$c->date_pricing->is_dst_in_zone('America/New_York'), 'date pricing is at non dst';
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{date_start} = $bet_params->{date_pricing} = $non_dst->plus_time_interval('1s');
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy,       'valid to buy';
    ok $c->market_is_inefficient, 'correctly triggered for non dst';
};

done_testing();
