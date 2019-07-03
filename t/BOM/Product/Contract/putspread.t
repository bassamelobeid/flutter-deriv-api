#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::FailWarnings;
use Try::Tiny;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

subtest 'config' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch - 1, 'R_100'], [100.10, $now->epoch + 1, 'R_100']);
    my $c = produce_contract({
        bet_type     => 'PUTSPREAD',
        underlying   => 'R_100',
        duration     => '5h',
        high_barrier => 100.11,
        low_barrier  => 99.01,
        currency     => 'USD',
        payout       => 100,
    });
    is $c->longcode->[0], 'Win up to [_7] [_6] if [_1]\'s exit tick is between [_4] and [_5] at [_3] after [_2].';
    is $c->longcode->[2][0], 'contract start time';
    is $c->longcode->[3]->{value}, 18000;
    ok !$c->is_binary, 'non-binary';
    ok $c->two_barriers,       'two barriers';
    is $c->pricing_code,       'PUTSPREAD', 'pricing code is PUTSPREAD';
    is $c->display_name,       'Put Spread', 'display name is Put Spread';
    is $c->category_code,      'callputspread', 'category code is callputspread';
    is $c->payout_type,        'non-binary', 'payout type is non-binary';
    is $c->payouttime,         'end', 'payout time is end';
    isa_ok $c->pricing_engine, 'Pricing::Engine::Callputspread';
    isa_ok $c->high_barrier,   'BOM::Product::Contract::Strike';
    isa_ok $c->low_barrier,    'BOM::Product::Contract::Strike';
};

subtest 'ask/bid price' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch - 1, 'R_100'], [100.10, $now->epoch + 1, 'R_100']);
    my $expiry = $now->plus_time_interval('2m');
    my $args   = {
        bet_type     => 'PUTSPREAD',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now,
        date_expiry  => $expiry,
        high_barrier => 100,
        low_barrier  => 99,
        currency     => 'USD',
        payout       => 100,
    };
    my $c = produce_contract($args);
    is $c->multiplier, 100, 'multiplier is 100';
    is $c->pricing_engine->theo_price, 0.0771698539615923, 'theo price 0.0771698539615923';
    is $c->commission_per_unit, 0.00115754780942388;
    cmp_ok $c->ask_price,       '==', 8.22, 'correct ask price';
    cmp_ok $c->bid_price,       '==', 7.6, 'correct bid price';
};

done_testing();
