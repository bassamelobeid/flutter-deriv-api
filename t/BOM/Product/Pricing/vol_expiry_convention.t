#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Exception;
use Test::NoWarnings;

use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);
use YAML::XS qw(LoadFile);
use BOM::Market::Underlying;
use Storable qw(dclone);

subtest 'tuesday to friday close' => sub {
    my $expiry = Date::Utility->new('2016-01-22 21:00:00');
    my $data   = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/vol_expiry_test.yml');

    foreach my $now (map { $_->[1] } sort { $a->[0] <=> $b->[0] } map { [Date::Utility->new($_)->epoch, Date::Utility->new($_)] } keys $data) {
        my $surface_data = $data->{$now->datetime}{surface_data};
        BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
            'currency',
            {
                symbol        => $_,
                recorded_date => $now
            }) for qw(USD JPY JPY-USD);
        BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
            'volsurface_delta',
            {
                underlying    => BOM::Market::Underlying->new('frxUSDJPY'),
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

        is $c->ask_probability->amount, $data->{$now->datetime}{ask_probability}, 'ask_probability';
        is $c->timeindays->amount,      $data->{$now->datetime}{timeindays},      'timeindays';
    }
    }
