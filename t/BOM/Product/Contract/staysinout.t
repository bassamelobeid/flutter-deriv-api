#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::Exception;
use Test::NoWarnings;
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);

initialize_realtime_ticks_db();
my $now = Date::Utility->new('10-Mar-2015');
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol => 'FOREX',
        date   => Date::Utility->new
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new
    }) for ('USD', 'JPY');
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch,
    quote      => 100,
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch + 1,
    quote      => 100.001,
});

my $args = {
    bet_type     => 'RANGE',
    underlying   => 'frxUSDJPY',
    date_start   => $now,
    date_pricing => $now,
    duration     => '1d',
    currency     => 'USD',
    payout       => 10,
    high_barrier => 100.020,
    low_barrier  => 99.080,
};

subtest 'range' => sub {
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Range';
        is $c->code,         'RANGE';
        is $c->pricing_code, 'RANGE';
        is $c->sentiment,    'low_vol';
        ok $c->is_path_dependent;
        is_deeply $c->supported_expiries, ['intraday', 'daily'];
        is_deeply $c->supported_start_types, ['spot'];
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated';
        isa_ok $c->greek_engine,   'BOM::Product::Pricing::Greeks::BlackScholes';
    }
    'generic';

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('1s');
        my $c = produce_contract($args);
        ok $c->high_barrier;
        ok $c->low_barrier;
        ok !$c->is_expired, 'not expired';
        $args->{date_pricing} = $now->plus_time_interval('2d');
        $c = produce_contract($args);
        ok $c->is_expired, 'expired';
        ok !$c->hit_tick;
        cmp_ok $c->value, '==', $c->payout, 'full payout';
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'frxUSDJPY',
            epoch      => $now->epoch + 3,
            quote      => 100.020,
        });
        $args->{date_pricing} = $now->plus_time_interval('3s');
        $c = produce_contract($args);
        ok $c->is_expired, 'expired';
        ok $c->hit_tick;
        cmp_ok $c->hit_tick->quote, '==', 100.020;
        cmp_ok $c->value, '==', 0.00, 'zero payout';
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'frxUSDJPY',
            epoch      => $now->epoch + 5,
            quote      => 100.010,
        });
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'frxUSDJPY',
            epoch      => $now->epoch + 6,
            quote      => 98.010,
        });
        $args->{date_start}   = $now->plus_time_interval('4s');
        $args->{date_pricing} = $now->plus_time_interval('6s');
        $c                    = produce_contract($args);
        ok $c->is_expired, 'expired';
        ok $c->hit_tick;
        cmp_ok $c->hit_tick->quote, '==', 98.010;
        cmp_ok $c->value, '==', 0.00, 'zero payout';
    }
    'expiry checks';
};

subtest 'up or down' => sub {
    lives_ok {
        $args->{bet_type} = 'UPORDOWN';
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Upordown';
        is $c->code,         'UPORDOWN';
        is $c->pricing_code, 'UPORDOWN';
        is $c->sentiment,    'high_vol';
        ok $c->is_path_dependent;
        is_deeply $c->supported_expiries, ['intraday', 'daily'];
        is_deeply $c->supported_start_types, ['spot'];
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated';
        isa_ok $c->greek_engine,   'BOM::Product::Pricing::Greeks::BlackScholes';
    }
    'generic';

    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'exchange',
        {
            symbol => 'RANDOM',
            date   => Date::Utility->new
        });
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency', {symbol => 'USD'});
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_flat',
        {
            symbol        => 'R_100',
            recorded_date => $now
        });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $now->epoch,
        quote      => 100,
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $now->epoch + 1,
        quote      => 100,
    });
    lives_ok {
        $args->{date_start}   = $now;
        $args->{date_pricing} = $now->plus_time_interval('10s');
        $args->{duration}     = '2m';
        $args->{underlying}   = 'R_100';
        $args->{low_barrier}  = 'S-10P';
        $args->{high_barrier} = 'S10P';
        my $c = produce_contract($args);
        ok $c->is_intraday;
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated';
        ok $c->high_barrier;
        cmp_ok $c->high_barrier->as_absolute, '==', 100.10, 'correct high barrier';
        ok $c->low_barrier;
        cmp_ok $c->low_barrier->as_absolute, '==', 99.90, 'correct low barrier';
        $args->{date_pricing} = $now->plus_time_interval('2m');
        $c = produce_contract($args);
        ok $c->is_expired, 'expired';
        ok $c->entry_tick;
        ok !$c->hit_tick;
        cmp_ok $c->value, '==', 0.00, 'zero payout';
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 5,
            quote      => 100.50,
        });
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->plus_time_interval('2m')->epoch,
            quote      => 100.01,
        });
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->plus_time_interval('2m')->epoch + 1,
            quote      => 100.02,
        });
        $c = produce_contract($args);
        ok $c->is_expired, 'expired';
        ok $c->hit_tick;
        cmp_ok $c->hit_tick->quote, '==', 100.50;
        cmp_ok $c->value, '==', $c->payout, 'full payout';
        $args->{date_start}   = $now->plus_time_interval('2m');
        $args->{date_pricing} = $now->plus_time_interval('3m');
        $c                    = produce_contract($args);
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->plus_time_interval('2m2s')->epoch,
            quote      => 99.80,
        });
        ok $c->is_expired, 'expired';
        ok $c->hit_tick;
        cmp_ok $c->hit_tick->quote, '==', 99.80;
        cmp_ok $c->value, '==', $c->payout, 'full payout';
    }
    'expiry checks';
};
