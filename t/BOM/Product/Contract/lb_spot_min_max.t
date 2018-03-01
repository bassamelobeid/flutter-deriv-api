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
    duration     => '1h',
    currency     => 'USD',
    multiplier   => 1,
    amount_type  => 'multiplier'
};

subtest 'spot min max' => sub {
    create_ticks(([100, $now->epoch - 1, 'R_100']));
    my $c = produce_contract($bet_params);

    is $c->pricing_spot, 100, 'pricing spot is available';
    is $c->spot_min,     100, 'spot min is available';
    is $c->spot_max,     100, 'spot max is available';
    ok $c->ask_price,    'can price';

    create_ticks(([101, $now->epoch, 'R_100'], [103, $now->epoch + 1, 'R_100']));
    $bet_params->{date_start}   = $now->epoch - 1;
    $bet_params->{date_pricing} = $now->epoch + 61;
    $c                          = produce_contract($bet_params);

    is $c->pricing_spot, 103, 'pricing spot is available';
    is $c->spot_min,     101, 'spot min is available';
    is $c->spot_max,     103, 'spot max is available';
    ok $c->bid_price,    'can price';
};

done_testing;

sub create_ticks {
    my @ticks = @_;

    Cache::RedisDB->flushall;
    BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;

    for my $tick (@ticks) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            quote      => $tick->[0],
            epoch      => $tick->[1],
            underlying => $tick->[2],
        });
    }
    Time::HiRes::sleep(0.1);

    return;
}
