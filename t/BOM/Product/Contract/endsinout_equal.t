#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::Warnings;
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);

initialize_realtime_ticks_db();
my $now = Date::Utility->new('10-Mar-2015');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for ('USD', 'JPY', 'JPY-USD');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
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

my $args = {
    bet_type     => 'EXPIRYMISSE',
    underlying   => 'frxUSDJPY',
    date_start   => $now,
    date_pricing => $now,
    duration     => '1d',
    currency     => 'USD',
    payout       => 10,
    high_barrier => 100.020,
    low_barrier  => 99.080,
};

subtest 'expiry miss' => sub {
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Expirymisse';
        is $c->code,         'EXPIRYMISSE';
        is $c->pricing_code, 'EXPIRYMISS';
        is $c->sentiment,    'high_vol';
        ok !$c->is_path_dependent;
        is_deeply $c->supported_expiries, ['intraday', 'daily'];
        isa_ok $c->pricing_engine_name,   'Pricing::Engine::EuropeanDigitalSlope';
        isa_ok $c->greek_engine,          'BOM::Product::Pricing::Greeks::BlackScholes';
    }
    'generic';

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('10s');
        my $c = produce_contract($args);
        ok $c->high_barrier;
        cmp_ok $c->high_barrier->as_absolute, '==', 100.020, 'correct high barrier';
        ok $c->low_barrier;
        cmp_ok $c->low_barrier->as_absolute, '==', 99.080, 'correct low barrier';
        ok !$c->is_expired, 'not expired';
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'frxUSDJPY',
            epoch      => $now->epoch + 5,
            quote      => 100,
        });
        ok !$c->is_expired, 'not expired';
        cmp_ok $c->value, '==', 0.00, 'zero payout';
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'frxUSDJPY',
            epoch      => $c->date_expiry->epoch,
            quote      => 100.020,
        });
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'frxUSDJPY',
            epoch      => $c->date_expiry->epoch + 1,
            quote      => 100.020,
        });
        $args->{date_pricing} = $c->date_expiry;
        $c = produce_contract($args);
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', 10, 'full payout';
        $args->{high_barrier} = 100.050;
        $c = produce_contract($args);
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', 0.00, 'zero payout';
    }
    'expiry checks';
};

subtest 'expiry range' => sub {
    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('1s');
        $args->{bet_type}     = 'EXPIRYRANGEE';
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Expiryrangee';
        is $c->code,                      'EXPIRYRANGEE';
        is $c->pricing_code,              'EXPIRYRANGE';
        ok $c->sentiment,                 'low_vol';
        is_deeply $c->supported_expiries, ['intraday', 'daily'];
        isa_ok $c->pricing_engine_name,   'Pricing::Engine::EuropeanDigitalSlope';
        isa_ok $c->greek_engine,          'BOM::Product::Pricing::Greeks::BlackScholes';
    }
    'generic';

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol        => 'R_100',
            recorded_date => $now,
        });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol => 'R_100',
            date   => Date::Utility->new
        });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol => 'USD',
            date   => Date::Utility->new
        });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $now->epoch + 1,
        quote      => 100,
    });
    lives_ok {
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
        cmp_ok $c->low_barrier->as_absolute, '==', 99.900, 'correct low barrier';
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 5,
            quote      => 100.50,
        });
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->plus_time_interval('2m')->epoch,
            quote      => 100.1,
        });
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->plus_time_interval('2m')->epoch + 1,
            quote      => 100.02,
        });
        ok !$c->is_expired, 'not expired';
        cmp_ok $c->value, '==', 0.00, 'zero payout';
        $args->{date_pricing} = $now->plus_time_interval('2m');
        $c = produce_contract($args);
        ok $c->is_expired, 'expired';
        ok $c->exit_tick;
        cmp_ok $c->value, '==', $c->payout, 'full payout';
        $args->{duration}     = '3m';
        $args->{date_pricing} = $now->plus_time_interval('3m');
        $c                    = produce_contract($args);
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->plus_time_interval('3m')->epoch,
            quote      => 100.50,
        });
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->plus_time_interval('3m1s')->epoch,
            quote      => 100.40,
        });
        ok $c->is_expired, 'expired';
        ok $c->exit_tick;
        cmp_ok $c->value, '==', 0.00, 'zero payout';
    }
    'expiry checks';
};
