#!/usr/bin/perl

use strict;
use warnings;

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;

use Test::More;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);

my $now = Date::Utility->new('2017-03-06 01:00:00');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(USD);

subtest 'opposite_contract for pricing_new' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::create_realtime_tick({
        quote      => 100,
        epoch      => $now->epoch,
        underlying => 'R_100'
    });

    my $c = produce_contract({
        bet_type    => 'CALL',
        date_start  => $now,
        pricing_new => 1,
        underlying  => 'R_100',
        duration    => '1h',
        barrier     => 'S0P',
        payout      => 100,
        currency    => 'USD',
    });

    ok $c->pricing_new, 'is pricing new';
    is $c->current_tick->quote, 100,                  'current tick is 100';
    is $c->code,                'CALL',               'contract code is CALL';
    is $c->timeinyears->amount, 3600 / (86400 * 365), 'contract duration is 1 day';

    BOM::Test::Data::Utility::FeedTestDatabase::create_realtime_tick({
        quote      => 102,
        epoch      => $now->epoch,
        underlying => 'R_100'
    });

    my $opposite_c = $c->opposite_contract;
    ok $opposite_c->pricing_new, 'is pricing new';
    is $opposite_c->current_tick->quote, 100,                  'current tick is 100';
    is $opposite_c->code,                'PUT',                'contract code is PUT';
    is $opposite_c->timeinyears->amount, 3600 / (86400 * 365), 'contract duration is 1 day';
    ok !$opposite_c->for_sale, 'not for sale';
};

subtest 'opposite_contract for sellback' => sub {
    my $now = Date::Utility->new;
    my $c   = produce_contract({
        bet_type   => 'CALL',
        date_start => $now->minus_time_interval('5s'),
        underlying => 'R_100',
        duration   => '1h',
        barrier    => 'S0P',
        payout     => 100,
        currency   => 'USD',
    });

    ok !$c->pricing_new, 'not pricing new';
    is $c->current_tick->quote, 102,                  'current tick is 102';
    is $c->code,                'CALL',               'contract code is CALL';
    is $c->timeinyears->amount, 3595 / (86400 * 365), 'contract duration is 1 day';

    BOM::Test::Data::Utility::FeedTestDatabase::create_realtime_tick({
        quote      => 105,
        epoch      => $now->epoch,
        underlying => 'R_100'
    });
    my $opposite_c = $c->opposite_contract_for_sale;
    ok $opposite_c->pricing_new, 'is pricing new';
    is $opposite_c->current_tick->quote, 105,                  'current tick is 105';
    is $opposite_c->code,                'PUT',                'contract code is PUT';
    is $opposite_c->timeinyears->amount, 3595 / (86400 * 365), 'contract duration is 1 day';
    ok $opposite_c->for_sale, 'not for sale';
};

done_testing();
