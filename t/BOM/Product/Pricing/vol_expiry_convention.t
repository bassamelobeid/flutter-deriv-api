#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Warnings;
use Test::Exception;
use Date::Utility;
use YAML::XS qw(LoadFile);
use Storable qw(dclone);
use Format::Util::Numbers qw/roundcommon/;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

Cache::RedisDB->flushall;

subtest 'tuesday to friday close' => sub {
    my $expiry = Date::Utility->new('2016-01-22 21:00:00');
    my $data   = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/vol_expiry_test.yml');

    foreach my $now (map { $_->[1] } sort { $a->[0] <=> $b->[0] } map { [Date::Utility->new($_)->epoch, Date::Utility->new($_)] } keys %$data) {
        my $surface_data = $data->{$now->datetime}{surface_data};
        BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
            'currency',
            {
                symbol        => $_,
                recorded_date => $now
            }) for qw(USD JPY JPY-USD);
        BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
            'volsurface_delta',
            {
                underlying    => create_underlying('frxUSDJPY'),
                surface       => $surface_data,
                recorded_date => $now
            });
        my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'frxUSDJPY',
            epoch      => $now->epoch,
            quote      => 118.290,
        });
        my $c = produce_contract({
            bet_type     => 'ONETOUCH',
            underlying   => 'frxUSDJPY',
            date_expiry  => $expiry,
            barrier      => 118.990,
            currency     => 'USD',
            payout       => 100,
            current_tick => $tick,
            date_start   => $now,
            date_pricing => $now,
        });

        is roundcommon(0.00001, $c->theo_probability->amount), roundcommon(0.00001, $data->{$now->datetime}{theo_probability}), 'theo_probability';
        is $c->timeindays->amount, $data->{$now->datetime}{timeindays}, 'timeindays';
    }
};
