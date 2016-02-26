#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Exception;
use Test::NoWarnings;
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
        is_deeply $c->supported_expiries,    ['tick'];
        is_deeply $c->supported_start_types, ['spot'];
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Asian';
        isa_ok $c->greek_engine,   'BOM::Product::Pricing::Greeks::Asian';
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
        ok !$c->barrier, 'barrier undef if not enough ticks';
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
        $args->{date_pricing} = $now->plus_time_interval('6s');
        $c                    = produce_contract($args);
        ok $c->is_expired, 'expired';
        cmp_ok $c->barrier->as_absolute, '>', 100, 'barrier > 100';
        cmp_ok $c->value, '==', $c->payout, 'full payout';
    }
    'expiry checks';
};
