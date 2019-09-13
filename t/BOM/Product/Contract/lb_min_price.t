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

initialize_realtime_ticks_db();

use BOM::Product::ContractFactory qw(produce_contract make_similar_contract);

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
    duration     => '15m',
    currency     => 'USD',
    multiplier       => 1,
};

subtest 'minimum lookback price and rounding strategy' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(([100, $now->epoch - 1, 'R_100']));
    my $c = produce_contract($bet_params);

    ok $c->ask_price, 'can price';
    is $c->ask_price, 0.5, 'ok. Min price of 0.50';

    $bet_params->{multiplier} = 1.9;

    $c = produce_contract($bet_params);

    ok $c->ask_price, 'can price';
    is $c->ask_price, 0.95, 'ok. correct price when multiplier is 1.9';

    $bet_params->{multiplier} = 19;

    $c = produce_contract($bet_params);

    ok $c->ask_price, 'can price';
    is $c->ask_price, 9.50, 'ok. correct price when multplier is 19';
};

done_testing;
