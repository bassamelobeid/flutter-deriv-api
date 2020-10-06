#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::Warnings;
use Test::Exception;
use Date::Utility;
use Format::Util::Numbers qw/roundcommon/;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory qw(produce_contract);

initialize_realtime_ticks_db();
my $now = Date::Utility->new('10-Mar-2015');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        recorded_date => $now,
        symbol        => $_,
    }) for qw( USD JPY JPY-USD );

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });

my @ticks_to_add = (
    [$now->epoch        => 100],
    [$now->epoch + 1    => 100],
    [$now->epoch + 2    => 100.020],
    [$now->epoch + 30   => 100.030],
    [$now->epoch + 3600 => 100.020],
    [$now->epoch + 3601 => 100]);

my $close_tick;

foreach my $pair (@ticks_to_add) {
    # We just want the last one to INJECT below
    # OHLC test DB does not work as expected.
    $close_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $pair->[0],
        quote      => $pair->[1],
    });
}

my $args = {
    bet_type     => 'ONETOUCH',
    underlying   => 'frxUSDJPY',
    date_start   => $now,
    date_pricing => $now,
    duration     => '21h',
    currency     => 'USD',
    payout       => 100,
    barrier      => '100.001',
};

subtest 'touch notouch' => sub {
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Onetouch';

        cmp_ok $c->ask_price,  '==', 100;
        cmp_ok $c->theo_price, '==', 99.95;
    }
    'touch barrier too close';

    $args->{barrier} = '99.000';
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Onetouch';

        cmp_ok $c->ask_price,  '==', 17.72;
        cmp_ok $c->theo_price, '==', 14.22;
    }
    'touch barrier too far';

    $args->{barrier}  = '100.001';
    $args->{bet_type} = 'NOTOUCH';
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Notouch';

        cmp_ok $c->ask_price,  '==', 5;
        cmp_ok $c->theo_price, '==', 0.12;
    }
    'no touch barrier too close';

    $args->{barrier} = '99.000';
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Notouch';

        cmp_ok $c->ask_price,  '==', 89.6;
        cmp_ok $c->theo_price, '==', 86.1;
    }
    'no touch barrier too far';

};

subtest 'range upordown' => sub {

    delete $args->{barriere};
    $args->{bet_type}     = 'RANGE';
    $args->{high_barrier} = '100.001';
    $args->{low_barrier}  = '99.999';
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Range';

        cmp_ok $c->ask_price,  '==', 5;
        cmp_ok $c->theo_price, '==', 0;
    }
    'range both barrier too close';

    $args->{high_barrier} = '101.000';
    $args->{low_barrier}  = '99.000';
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Range';

        cmp_ok $c->ask_price,  '==', 84.44;
        cmp_ok $c->theo_price, '==', 80.94;
    }
    'range both barrier too far';

    $args->{high_barrier} = '101.000';
    $args->{low_barrier}  = '99.999';
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Range';

        cmp_ok $c->ask_price,  '==', 5;
        cmp_ok $c->theo_price, '==', 0.14;
    }
    'range one barrier too far and one barrier too close';

    #UPORDOWN

    $args->{bet_type}     = 'UPORDOWN';
    $args->{high_barrier} = '100.001';
    $args->{low_barrier}  = '99.999';
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Upordown';

        cmp_ok $c->ask_price,  '==', 100;
        cmp_ok $c->theo_price, '==', 100;

    }
    'upordown both barrier too close';

    $args->{high_barrier} = '101.000';
    $args->{low_barrier}  = '99.000';
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Upordown';

        cmp_ok $c->ask_price,  '==', 23.2;
        cmp_ok $c->theo_price, '==', 19.7;
    }
    'upordown both barrier too far';

    $args->{high_barrier} = '101.000';
    $args->{low_barrier}  = '99.999';
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Upordown';

        cmp_ok $c->ask_price,  '==', 100;
        cmp_ok $c->theo_price, '==', 99.87;
    }
    'uprodown one barrier too far and one barrier too close';
};
