#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::Warnings;
use Test::Exception;
use Date::Utility;
use JSON::MaybeXS;
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
        symbol        => $_,
        recorded_date => $now
    }) for ('USD', 'JPY-USD');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });
my @ticks_to_add = (
    ['frxUSDJPY', $now->epoch                    => 100],
    ['frxUSDJPY', $now->epoch + 1                => 100.001],
    ['frxUSDJPY', $now->epoch + 3                => 100.020],
    ['frxUSDJPY', $now->epoch + 5                => 100.010],
    ['frxUSDJPY', $now->epoch + 6                => 98.010],
    ['R_100',     $now->epoch                    => 100],
    ['R_100',     $now->epoch + 1                => 100],
    ['R_100',     $now->epoch + 5                => 100.50],
    ['R_100',     $now->epoch + 120              => 100.01],
    ['R_100',     $now->epoch + 121              => 100.02],
    ['R_100',     $now->epoch + 180              => 99.80],
    ['R_100',     $now->epoch + 2 * 24 * 60 * 60 => 99.80],
);

my $close_tick;

foreach my $triple (@ticks_to_add) {
    # We just want the last tick to INJECT below sine the test DB OHLC doesn't seem to work.
    $close_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => $triple->[0],
        epoch      => $triple->[1],
        quote      => $triple->[2],
    });
}

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
        is $c->code,          'RANGE';
        is $c->pricing_code,  'RANGE';
        cmp_ok $c->ask_price, '==', 0.5;
        is roundcommon(0.001, $c->pricing_vol), 0.177;
        is $c->sentiment, 'low_vol';
        ok $c->is_path_dependent;
        is_deeply $c->supported_expiries, ['intraday', 'daily'];
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
        $args->{date_pricing} = $now->plus_time_interval('3s');
        $c = produce_contract($args);
        ok $c->is_expired, 'expired';
        ok $c->hit_tick;
        cmp_ok $c->hit_tick->quote, '==', 100.020;
        cmp_ok $c->value, '==', 0.00, 'zero payout';
        $args->{date_start}   = $now->plus_time_interval('4s');
        $args->{date_pricing} = $now->plus_time_interval('6s');
        $c                    = produce_contract($args);
        ok $c->is_expired, 'expired';
        ok $c->hit_tick;
        cmp_ok $c->hit_tick->quote, '==', 98.010;
        cmp_ok $c->value, '==', 0.00, 'zero payout';
        $args->{high_barrier}       = 200;
        $args->{low_barrier}        = 90;
        $args->{date_pricing}       = $now->plus_time_interval('2d');
        $args->{exit_tick}          = $close_tick;                      # INJECT OHLC since cannot find it in the test DB
        $args->{is_valid_exit_tick} = 1;
        $c                          = produce_contract($args);
        ok $c->is_expired, 'expired';
        ok !$c->hit_tick, 'no hit tick';
        cmp_ok $c->value, '==', $c->payout, 'full payout';
        delete $args->{exit_tick};
        delete $args->{is_valid_exit_tick};
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
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated';
        isa_ok $c->greek_engine,   'BOM::Product::Pricing::Greeks::BlackScholes';
    }
    'generic';

    lives_ok {
        $args->{date_start}   = $now;
        $args->{date_pricing} = $now->plus_time_interval('10s');
        $args->{duration}     = '2m';
        $args->{underlying}   = 'R_100';
        $args->{low_barrier}  = 'S-10P';
        $args->{high_barrier} = 'S10P';
        my $c = produce_contract($args);
        ok $c->is_intraday;
        isa_ok $c->pricing_engine_name, 'Pricing::Engine::BlackScholes';
        ok $c->high_barrier;
        cmp_ok $c->high_barrier->as_absolute, '==', 100.10, 'correct high barrier';
        ok $c->low_barrier;
        cmp_ok $c->low_barrier->as_absolute, '==', 99.90, 'correct low barrier';
        $args->{date_pricing} = $now->plus_time_interval('2m');
        $c = produce_contract($args);
        ok $c->is_expired, 'expired';
        ok $c->hit_tick,   'hit tick';
        cmp_ok $c->hit_tick->quote, '==', 100.50;
        cmp_ok $c->value, '==', $c->payout, 'full payout';
        $args->{high_barrier} = 'S1000P';
        $c = produce_contract($args);
        ok $c->is_expired, 'expired';
        ok $c->entry_tick, 'entry tick';
        ok !$c->hit_tick, 'No hit tick';
        cmp_ok $c->value, '==', 0.00, 'zero payout';
        $args->{high_barrier} = 'S10P';
        $args->{date_start}   = $now->plus_time_interval('2m');
        $args->{date_pricing} = $now->plus_time_interval('3m');
        $c                    = produce_contract($args);
        ok $c->is_expired, 'expired';
        ok $c->hit_tick;
        cmp_ok $c->hit_tick->quote, '==', 99.80;
        cmp_ok $c->value, '==', $c->payout, 'full payout';
    }
    'expiry checks';
};
