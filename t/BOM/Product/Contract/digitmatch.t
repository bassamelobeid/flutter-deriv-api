#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::NoWarnings;
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestMD qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);

initialize_realtime_ticks_db();
my $now = Date::Utility->new('10-Mar-2015');
BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'currency',
    {
        symbol => 'USD',
        date   => Date::Utility->new
    });
my $args = {
    bet_type     => 'DIGITMATCH',
    underlying   => 'R_100',
    date_start   => $now,
    date_pricing => $now,
    duration     => '5t',
    currency     => 'USD',
    payout       => 10,
    barrier      => '9',
};

subtest 'digits test it all' => sub {
    lives_ok {
        my $c = produce_contract($args);
        is $c->code,            'DIGITMATCH';
        is $c->pricing_code,    'DIGITMATCH';
        is $c->sentiment,       'match';
        is $c->other_side_code, 'DIGITDIFF';
        is $c->category->code, 'digits';
        is_deeply $c->supported_expiries,    ['tick'];
        is_deeply $c->supported_start_types, ['spot'];
        isa_ok $c, 'BOM::Product::Contract::Digitmatch';
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Digits';
        isa_ok $c->greek_engine,   'BOM::Product::Pricing::Greeks::Digits';
        ok $c->tick_expiry;
        is $c->tick_count,      5;
        is $c->ticks_to_expiry, 5;
    }
    'generic';

    for (0 .. 4) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + $_
        });
    }

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('4s');
        my $c = produce_contract($args);
        ok !$c->exit_tick,  'first tick is next tick';
        ok !$c->is_expired, 'not expired';
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 5,
            quote      => 100.09,
        });
        $c = produce_contract($args);
        is $c->exit_tick->quote, 100.09, 'correct exit tick';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'full payout';
    }
    'check expiry';
};
