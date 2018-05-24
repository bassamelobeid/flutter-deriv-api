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
    _create_ticks([['R_100', $now->epoch - 1, 100], ['R_100', $now->epoch + 1, 100.10]]);
    my $c = produce_contract({
        bet_type     => 'CALLSPREAD',
        underlying   => 'R_100',
        duration     => '5h',
        high_barrier => 100.11,
        low_barrier  => 99.01,
        currency     => 'USD',
        payout       => 100,
    });
    is $c->longcode->[0], 'Win up to [_7] [_6] if [_1]\'s exit tick is between [_5] and [_4] or [_7] [_6] if it exceeds [_4] at [_3] after [_2].';
    is $c->longcode->[2][0], 'contract start time';
    is $c->longcode->[3]->{value}, 18000;
    ok !$c->is_binary, 'non-binary';
    ok $c->two_barriers,       'two barriers';
    is $c->pricing_code,       'CALLSPREAD', 'pricing code is CALLSPREAD';
    is $c->display_name,       'Call Spread', 'display name is Call Spread';
    is $c->category_code,      'callputspread', 'category code is callputspread';
    is $c->payout_type,        'non-binary', 'payout type is non-binary';
    is $c->payouttime,         'end', 'payout time is end';
    isa_ok $c->pricing_engine, 'Pricing::Engine::Callputspread';
    isa_ok $c->high_barrier,   'BOM::Product::Contract::Strike';
    isa_ok $c->low_barrier,    'BOM::Product::Contract::Strike';
};

subtest 'expiry conditions' => sub {
    _create_ticks([['R_100', $now->epoch - 1, 100], ['R_100', $now->epoch + 1, 100.10]]);
    my $expiry = $now->plus_time_interval('2m');
    my $args   = {
        bet_type     => 'CALLSPREAD',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now,
        date_expiry  => $expiry,
        high_barrier => 100.11,
        low_barrier  => 99.01,
        currency     => 'USD',
        payout       => 100,
    };
    my $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';
    $args->{date_pricing} = $expiry;
    $c = produce_contract($args);
    ok $c->is_expired, 'expired without exit tick';
    is $c->exit_tick->quote, '100.1', 'exit tick is the latest available tick (100.1)';
    ok !$c->is_settleable, 'cannot be settled';
    _create_ticks([['R_100', $expiry->epoch, 99], ['R_100', $expiry->epoch + 1, 100.10]]);
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    is $c->exit_tick->quote, '99', 'exit tick is 99';
    ok $c->is_settleable, 'can be settled';

    $args->{high_barrier} = 101;
    $args->{low_barrier}  = 99;
    _create_ticks([['R_100', $expiry->epoch, 100], ['R_100', $expiry->epoch + 1, 100.10]]);
    $c = produce_contract($args);
    is $c->multiplier, 50, 'multiplier is 50 for a payout of 100 where the barriers are 101, 99';
    ok $c->is_expired, 'expired';
    ok $c->is_settleable, 'can be settled';
    is $c->exit_tick->quote, 100, 'exit tick is 100';
    is $c->value, 50, 'value of contract is 50';
    _create_ticks([['R_100', $expiry->epoch, 102], ['R_100', $expiry->epoch + 1, 100.10]]);
    $c = produce_contract($args);
    ok $c->is_expired,    'expired';
    ok $c->is_settleable, 'can be settled';
    is $c->exit_tick->quote, 102, 'exit tick is 102';
    is $c->value, 100, 'value of contract is 100';
    _create_ticks([['R_100', $expiry->epoch, 98], ['R_100', $expiry->epoch + 1, 100.10]]);
    $c = produce_contract($args);
    ok $c->is_expired,    'expired';
    ok $c->is_settleable, 'can be settled';
    is $c->exit_tick->quote, 98, 'exit tick is 98';
    is $c->value, 0, 'value of contract is 0';
};

subtest 'ask/bid price' => sub {
    _create_ticks([['R_100', $now->epoch - 1, 100], ['R_100', $now->epoch + 1, 100.10]]);
    my $expiry = $now->plus_time_interval('2m');
    my $args   = {
        bet_type     => 'CALLSPREAD',
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
    is $c->pricing_engine->theo_price, 0.9228300523766, 'theo price 0.9228300523766';
    is $c->commission_per_unit, 0.013842450785649, '';
    is $c->ask_price,           93.67,   'correct ask price';
    is $c->bid_price,           90.9,   'correct bid price';
};

sub _create_ticks {
    my $ticks = shift;

    BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;
    foreach my $t (@$ticks) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => $t->[0],
            epoch      => $t->[1],
            quote      => $t->[2],
        });
    }

    return;
}

done_testing();
