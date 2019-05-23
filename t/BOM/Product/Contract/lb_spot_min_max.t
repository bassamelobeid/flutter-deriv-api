#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings 'warnings';
use Test::Deep;

use Time::HiRes;
use Cache::RedisDB;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Config::RedisReplicated;
use BOM::MarketData qw(create_underlying);

initialize_realtime_ticks_db();

use BOM::Product::ContractFactory qw(produce_contract make_similar_contract);
use BOM::Market::DataDecimate;

my $now = Date::Utility->new;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => 'USD'});

#create an empty un-used even so ask_price won't fail preparing market data for pricing engine
#Because the code to prepare market data is called for all pricings in Contract
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                event_name   => 'FOMC',
            }]});

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'partial_trading',
    {
        type          => 'early_closes',
        recorded_date => Date::Utility->new('2016-01-01'),
        # dummy early close
        calendar => {
            '22-Dec-2016' => {
                '18h00m' => ['FOREX'],
            },
        },
    });

my $bet_params = {
    bet_type     => 'LBFLOATCALL',
    underlying   => 'R_100',
    date_start   => $now,
    date_pricing => $now,
    duration     => '1h',
    currency     => 'USD',
    amount       => 1,
    amount_type  => 'multiplier'
};

#setup raw cache for R_100
my $single_data = {
    'symbol' => 'R_100',
    'epoch'  => $now->epoch - 1,
    'quote'  => '100',
};
my $decimate_cache = BOM::Market::DataDecimate->new({market => 'volidx'});

my $key = $decimate_cache->_make_key('R_100', 0);
$decimate_cache->_update($decimate_cache->redis_write, $key, $now->epoch - 1, $decimate_cache->encoder->encode($single_data));

$single_data = {
    'symbol' => 'R_100',
    'epoch'  => $now->epoch,
    'quote'  => '101',
};

$decimate_cache->_update($decimate_cache->redis_write, $key, $now->epoch, $decimate_cache->encoder->encode($single_data));

$single_data = {
    'symbol' => 'R_100',
    'epoch'  => $now->epoch + 1,
    'quote'  => '103',
};

$decimate_cache->_update($decimate_cache->redis_write, $key, $now->epoch + 1, $decimate_cache->encoder->encode($single_data));

subtest 'spot min max lbfloatcall' => sub {

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(([100, $now->epoch - 1, 'R_100']));
    my $c = produce_contract($bet_params);

    is $c->pricing_spot, 100, 'pricing spot is available';
    is $c->spot_min_max($c->date_start_plus_1s)->{low},  100, 'spot min is available';
    is $c->spot_min_max($c->date_start_plus_1s)->{high}, 100, 'spot max is available';
    ok $c->ask_price, 'can price';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(([101, $now->epoch, 'R_100'], [103, $now->epoch + 1, 'R_100']));
    $bet_params->{date_start}   = $now->epoch - 1;
    $bet_params->{date_pricing} = $now->epoch + 61;
    $c                          = produce_contract($bet_params);

    is $c->pricing_spot, 103, 'pricing spot is available';
    is $c->spot_min_max($c->date_start_plus_1s)->{low}, 101, 'spot min is available';
    is $c->barrier->as_absolute, '101.00', 'barrier is correct';
    is $c->spot_min_max($c->date_start_plus_1s)->{high}, 103, 'spot max is available';
    ok $c->bid_price, 'can price';
};

subtest 'spot min max lbfloatput' => sub {

    $bet_params->{bet_type} = 'LBFLOATPUT';

    my $c = produce_contract($bet_params);

    is $c->barrier->as_absolute, '103.00', 'barrier is correct';
};

subtest 'spot min max lbhighlow' => sub {

    $bet_params->{bet_type} = 'LBHIGHLOW';

    my $c = produce_contract($bet_params);

    is $c->high_barrier->as_absolute, '103.00', 'high barrier is correct';
    is $c->low_barrier->as_absolute,  '101.00', 'low barrier is correct';

    # high barrier should be 101 when we pass sell time as below
    $bet_params->{sell_time} = $now->epoch;
    $c = produce_contract($bet_params);

    is $c->high_barrier->as_absolute, '101.00', 'high barrier is correct';
    is $c->low_barrier->as_absolute,  '101.00', 'low barrier is correct';
};

done_testing;
