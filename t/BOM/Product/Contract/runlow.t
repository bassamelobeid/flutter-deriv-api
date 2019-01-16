#!/usr/bin/perl

use strict;
use warnings;

use Test::Deep;
use Test::More;
use Test::Warnings;
use Test::Exception;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;
use Try::Tiny;

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_100',
    epoch      => $now->epoch,
    quote      => 99
});
my $args = {
    bet_type     => 'RUNLOW',
    date_start   => $now,
    date_pricing => $now,
    underlying   => 'R_100',
    duration     => '1t',
    currency     => 'USD',
    payout       => 100,
    barrier      => 'S0P',
};

subtest 'RUNLOW - config check' => sub {
    my $c = produce_contract($args);
    is $c->code,                'RUNLOW',                         'code - RUNLOW';
    is $c->pricing_engine_name, 'Pricing::Engine::HighLow::Runs', 'engine - Pricing::Engine::HighLow::Runs';
    is $c->tick_count,          1,                                'tick count is 1';
    is $c->selected_tick,       1,                                'selected_tick is 1';
    is $c->barrier->as_absolute, '99.00', 'barrier is equals to current spot';
    ok $c->theo_probability->amount;
};

subtest 'RUNLOW - probability check' => sub {
    foreach my $tick_number (1 .. 5) {
        $args->{duration} = $tick_number . 't';
        my $c = produce_contract($args);
        ok abs($c->theo_probability->amount - 1 / (2**$tick_number)) < 0.0000001, 'correct theo probability for tick_count(' . $tick_number . ')';
    }
};

subtest 'RUNLOW - expiration check' => sub {
    _create_ticks($now->epoch, [100]);    # [entry_tick]
    $args->{date_pricing} = $now->epoch + 1;
    $args->{duration}     = '1t';
    my $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';
    _create_ticks($now->epoch, [100, 100]);    # [entry_tick, first_tick ...]
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    is $c->value, 0, 'expired worthless if first tick is equals to barrier';
    _create_ticks($now->epoch, [100, 99, 99]);    # [entry_tick, first_tick ...]
    $args->{duration} = '2t';
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    is $c->value, 0, 'expired worthless if first and second ticks are equal';
    _create_ticks($now->epoch, [100, 99, 100]);    # [entry_tick, first_tick ...]
    $args->{duration} = '2t';
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    is $c->value, 0, 'expired worthless if second tick is higher than first tick';
    _create_ticks($now->epoch, [100, 99, 98, 100, 96]);    # [entry_tick, first_tick ...]
    $args->{duration} = '5t';
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    is $c->value, 0, 'expired worthless if third tick is higher than second tick without a complete set of ticks';
    _create_ticks($now->epoch, [100, 99, 98, 97]);         # [entry_tick, first_tick ...]
    $args->{duration} = '5t';
    $c = produce_contract($args);
    ok !$c->is_expired, 'not expired if we only have 3 out of 5 ticks';
    _create_ticks($now->epoch, [100, 99, 96, 96, 95]);     # [entry_tick, first_tick ...]
    $args->{duration} = '5t';
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    is $c->value, 0, 'expired worthless 2 out of the 4 ticks are identical in a 5-tick contract';
    _create_ticks($now->epoch, [100, 99, 98, 97, 95, 94]);    # [entry_tick, first_tick ...]
    $args->{duration} = '5t';
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    is $c->value, 100, 'expired with full payout if the next 5 ticks are higher than the previous tick';
};

subtest 'RUNLOW - shortcode & longcode' => sub {
    note("argument to contract shortcode");
    my $c = produce_contract($args);
    is $c->shortcode, 'RUNLOW_R_100_100_' . $now->epoch . '_5T_S0P_0', 'shortcode is correct';
    is_deeply(
        $c->longcode,
        [
            'Win payout if [_1] falls successively for [plural,_3,%d tick, %d ticks] after the entry spot.',
            ['Volatility 100 Index'], ['first tick'], [5], ['entry spot']
        ],
        'longcode matches'
    );

    note('shortcode to contract');
    $c = produce_contract($c->shortcode, 'USD');
    is $c->code, 'RUNLOW', 'code is RUNLOW';
    is $c->underlying->symbol, 'R_100', 'underlying symbol is R_100';
    is $c->payout, 100, 'payout is 100';
    is $c->barrier->as_absolute, '100.00', 'barrier is 100.00';
    is $c->selected_tick, 5, 'selected_tick is 5';
};

subtest 'passing in barrier' => sub {
    $args->{barrier} = 'S1000P';
    my $output = try { produce_contract($args) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        $_->error_code;
    };
    is $output, "InvalidBarrier";
    $args->{barrier} = '+0.001';
    $output = try { produce_contract($args) }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        $_->error_code;
    };
    is $output, "InvalidBarrier";
};

subtest 'passing in non-tick duration' => sub {
    $args->{barrier}  = 'S0P';
    $args->{duration} = '5m';
    my $c = produce_contract($args);
    my $output = try { $c->ask_price }
    catch {
        isa_ok $_, 'BOM::Product::Exception';
        $_->error_code;
    };
    is $output, "TradingDurationNotAllowed";
};

sub _create_ticks {
    my ($epoch, $quotes) = @_;

    BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;
    foreach my $q (@$quotes) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => ++$epoch,
            quote      => $q
        });
    }
    return;
}
done_testing();
