#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use YAML::XS qw(LoadFile);
use BOM::Market::DataDecimate;
use Date::Utility;
use BOM::MarketData qw(create_underlying);

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory qw(produce_contract);

# setup ticks
my $now        = Date::Utility->new('2017-08-07 08:03:27');
my $underlying = create_underlying('frxEURJPY', $now);
my $ticks      = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/vol_spread_across_barriers_ticks.yml');
my $decimator  = BOM::Market::DataDecimate->new;
my $key        = $decimator->_make_key($underlying->symbol, 1);
foreach my $single_data (@$ticks) {
    $decimator->_update($decimator->redis_write, $key, $single_data->{decimate_epoch}, $decimator->encoder->encode($single_data));
}

# test time
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $underlying->symbol,
        recorded_date => $now
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(EUR JPY EUR-JPY);
my $current_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxEURJPY',
    quote      => 130.819,
    epoch      => $now->epoch
});

subtest 'test prices across barriers' => sub {
    foreach my $d ([130.581, 777], [130.485, 851], [130.381, 912], [130.301, 946], [130.221, 970]) {
        my $c = produce_contract({
            bet_type     => 'CALLE',
            currency     => 'JPY',
            date_start   => $now,
            date_pricing => $now,
            date_expiry  => Date::Utility->new('2017-08-07 10:00:00'),
            barrier      => $d->[0],
            payout       => 1000,
            underlying   => $underlying,
            current_tick => $current_tick,
            backprice    => 0
        });
        is $c->ask_price, $d->[1], "price is $d->[1] for barrier $d->[0]";
    }
};

done_testing();
