#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Format::Util::Numbers qw(roundnear);
use Date::Utility;
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
    bet_type     => 'LBFIXEDCALL',
    underlying   => 'frxUSDJPY',
    date_start   => $now,
    date_pricing => $now,
    duration     => '1h',
    currency     => 'USD',
    payout       => 10,
    barrier      => 'S20P',
};

subtest 'lbfixedcall' => sub {
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Lbfixedcall';
        is $c->payouttime,   'end';
        is $c->code,         'LBFIXEDCALL';
        is $c->pricing_code, 'LBFIXEDCALL';

        is roundnear(0.00001, $c->theo_price), 0.13530;
        is roundnear(0.001, $c->pricing_vol), 0.181;

        is $c->sentiment, undef;
        ok !$c->is_path_dependent;
        is_deeply $c->supported_expiries, ['intraday', 'daily'];
        isa_ok $c->pricing_engine, 'Pricing::Engine::Lookbacks';
        
    }
    'generic';

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('1s');
        my $c = produce_contract($args);
        ok $c->entry_tick;
        cmp_ok $c->entry_tick->quote, '==', 100.000, 'correct entry tick';
        ok $c->barrier;
        cmp_ok $c->barrier->as_absolute, '==', 100.020, 'correct barrier';
        ok !$c->is_expired, 'not expired';
        
        $args->{date_pricing} = $now->plus_time_interval('2s');
        $c = produce_contract($args);
        cmp_ok $c->date_pricing->epoch, '<', $c->date_expiry->epoch, 'date pricing is before expiry';
        ok !$c->is_expired, 'not expired';
        
        $args->{barrier}      = 'S40P';
        $args->{date_pricing} = $now->plus_time_interval('1h1s');
        $c                    = produce_contract($args);
        cmp_ok $c->date_pricing->epoch, '>', $c->date_expiry->epoch, 'after expiry';
        ok $c->is_expired, 'expired';
        
    }
    'expiry checks';
};

subtest 'lbfixedput' => sub {
    lives_ok {
        $args->{bet_type}     = 'LBFIXEDPUT';
        $args->{date_pricing} = $now;
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Lbfixedput';
        is $c->payouttime,   'end';
        is $c->code,         'LBFIXEDPUT';
        is $c->pricing_code, 'LBFIXEDPUT';
        
        ok !$c->is_path_dependent;
        is_deeply $c->supported_expiries, ['intraday', 'daily'];
        isa_ok $c->pricing_engine, 'Pricing::Engine::Lookbacks';
        
    }
    'generic';

    lives_ok {
        $args->{duration} = '1d';
        $args->{barrier}  = 100.030;
        my $c = produce_contract($args);
        isa_ok $c->pricing_engine, 'Pricing::Engine::Lookbacks';
        
        is $c->expiry_type, 'daily';
        ok !$c->is_expired, 'not expired';
        
        $args->{date_pricing} = $args->{date_start}->epoch + 31;
        $c = produce_contract($args);
        ok !$c->is_expired, 'expired';
        
        
        $args->{barrier}      = 100.050;
        $args->{date_pricing} = $now->truncate_to_day->plus_time_interval('2d');
        $args->{exit_tick}    = $close_tick;                                       # INJECT OHLC since cannot find it in the test DB.
        $args->{is_valid_exit_tick}    = 1;
        $c                    = produce_contract($args);
        cmp_ok $c->date_pricing->epoch, '>', $c->date_expiry->epoch, 'after expiry';
        ok $c->is_expired, 'expired';
        
        
    }
    'expiry checks';
};
