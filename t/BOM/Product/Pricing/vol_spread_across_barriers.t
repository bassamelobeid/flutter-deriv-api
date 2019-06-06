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
use Test::MockModule;

# setup ticks
my $now        = Date::Utility->new('2017-08-07 08:03:27');
my $underlying = create_underlying('frxEURJPY', $now);
my $ticks      = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/vol_spread_across_barriers_ticks.yml');
my $decimator  = BOM::Market::DataDecimate->new({market => 'forex'});
my $key        = $decimator->_make_key($underlying->symbol, 1);
foreach my $single_data (@$ticks) {
    $decimator->_update($decimator->redis_write, $key, $single_data->{decimate_epoch}, $decimator->encoder->encode($single_data));
}

my $mocked = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked->mock(
    'decimate_cache_get',
    sub {
        $decimator->_get_decimate_from_cache({
                symbol      => $_[1]->{underlying}->symbol,
                start_epoch => $_[1]->{start_epoch},
                end_epoch   => $_[1]->{end_epoch}});
    });
# test time
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $underlying->symbol,
        recorded_date => Date::Utility->new('2017-08-07 07:46:11'),
        surface       => {
            1 => {
                'expiry_date' => '08-Aug-17',
                'smile'       => {
                    25 => 0.0942375,
                    50 => 0.09335,
                    75 => 0.0963125
                },
                'tenor'      => 'ON',
                'vol_spread' => {
                    25 => 0.0392857142857143,
                    50 => 0.0275,
                    75 => 0.0392857142857143
                },
            },
            7 => {
                'smile' => {
                    25 => 0.0760375,
                    50 => 0.0752,
                    75 => 0.0781125,
                },
                'tenor'      => '1W',
                'vol_spread' => {
                    25 => 0.0178571428571429,
                    50 => 0.0125,
                    75 => 0.0178571428571429,
                }}
        },
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
    foreach my $d ([130.581, 970], [130.485, 1000], [130.381, 1000], [130.301, 1000], [130.221, 1000]) {
        my $c = produce_contract({
            bet_type             => 'CALLE',
            currency             => 'JPY',
            date_start           => $now,
            date_pricing         => $now,
            product_type         => 'multi_barrier',
            trading_period_start => $now->epoch,
            date_expiry          => Date::Utility->new('2017-08-07 10:00:00'),
            barrier              => $d->[0],
            payout               => 1000,
            underlying           => $underlying,
            current_tick         => $current_tick,
        });
        is $c->ask_price, $d->[1], "price is $d->[1] for barrier $d->[0] shortcode " . $c->shortcode;
    }
};

done_testing();
