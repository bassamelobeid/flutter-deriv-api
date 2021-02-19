#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::Warnings;
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);

initialize_realtime_ticks_db();
my $now = Date::Utility->new('10-Mar-2015');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'USD',
        date   => Date::Utility->new
    });
my $args = {
    bet_type     => 'ASIANU',
    underlying   => 'R_100',
    date_start   => $now,
    date_pricing => $now,
    duration     => '5t',
    currency     => 'USD',
    payout       => 10,
};

subtest 'asian' => sub {
    lives_ok {
        my $c = produce_contract($args);
        isa_ok $c, 'BOM::Product::Contract::Asianu';
        is $c->code, 'ASIANU';
        is $c->pricing_code => 'CALL';
        is $c->sentiment, 'up';
        ok $c->tick_expiry;
        is_deeply $c->supported_expiries, ['tick'];
        is $c->pricing_engine_name,       'Pricing::Engine::BlackScholes';
        isa_ok $c->greek_engine,          'BOM::Product::Pricing::Greeks::BlackScholes';
    }
    'generic';

    lives_ok {
        my $c = produce_contract($args);
        ok !$c->barrier, 'barrier undef';
        for (0 .. 4) {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                underlying => 'R_100',
                epoch      => $now->epoch + $_,
                quote      => 100
            });
        }
        $args->{date_pricing} = $now->plus_time_interval('5s');
        $c = produce_contract($args);
        is $c->barrier->as_absolute + 0, 100, 'barrier is the average';
        $args->{date_pricing} = $now->plus_time_interval('5m1s');
        $c = produce_contract($args);
        ok $c->is_after_settlement, 'after expiry';
        ok !$c->barrier, 'barrier undef if not enough ticks after expiry';
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 5,
            quote      => 100
        });
        $c = produce_contract($args);
        ok $c->barrier, 'has barrier';
        cmp_ok $c->barrier->as_absolute, '==', 100.000, 'barrier with correct pip size';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', 0.00, 'zero payout';
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 6,
            quote      => 101
        });
        $args->{date_start}   = $now->plus_time_interval('1s');
        $args->{date_pricing} = $now->plus_time_interval('12s');
        $c                    = produce_contract($args);
        ok $c->is_expired, 'expired';
        cmp_ok $c->barrier->as_absolute, '>', 100, 'barrier > 100';
        cmp_ok $c->value, '==', $c->payout, 'full payout';
    }
    'expiry checks';
};

subtest 'supplied barrier build' => sub {
    my $now          = Date::Utility->new;
    my $current_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $now->epoch,
        quote      => 101
    });
    # next tick
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $now->epoch + 1,
        quote      => 102
    });
    my $params = {
        bet_type     => 'ASIANU',
        underlying   => 'R_100',
        duration     => '5t',
        currency     => 'USD',
        payout       => 10,
        current_tick => $current_tick,
    };
    my $c = produce_contract($params);
    ok $c->pricing_new, 'pricing new';
    ok !defined $c->barrier, 'undefined barrier';
    is $c->barriers_for_pricing->{barrier1}, 101, 'correct barrier for pricing';
    $params->{date_start}   = $now;
    $params->{date_pricing} = $now->plus_time_interval('1s');
    $c                      = produce_contract($params);
    ok !$c->pricing_new, 'not pricing new';
    ok $c->barrier, 'barrier defined';
    is $c->barrier->as_absolute + 0, 102, 'correct barrier at date_pricing';
    is $c->barriers_for_pricing->{barrier1} + 0, 102, 'correct barrier for pricing';
};
