#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::MockModule;

use Date::Utility;
use Math::Util::CalculatedValue::Validatable;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Config::QuantsConfig;
use BOM::Config::Chronicle;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

my $now = Date::Utility->new('2017-09-07');
my $qc  = BOM::Config::QuantsConfig->new(
    chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader,
    chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer,
    recorded_date    => $now->minus_time_interval('4h'),
);

my $args = {
    bet_type     => 'CALL',
    barrier      => 'S10P',
    date_start   => $now,
    date_pricing => $now,
    duration     => '1h',
    payout       => 10,
    currency     => 'JPY',
};

my $mock_intraday = Test::MockModule->new('BOM::Product::Pricing::Engine::Intraday::Forex');
$mock_intraday->mock(
    'base_probability',
    sub {
        return Math::Util::CalculatedValue::Validatable->new({
            name        => 'base_probability',
            set_by      => 'test',
            description => 'test',
            base_amount => 0.45,
        });
    });
my $mock_underlying = Test::MockModule->new('Quant::Framework::Underlying');
$mock_underlying->mock('pip_size', sub { 0.001 });
my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
$mock_contract->mock('current_spot', sub { 100 });
my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'test',
    quote      => 100,
    epoch      => time
});
$mock_contract->mock('_build_basis_tick', sub { $tick });
my $mock_barrier = Test::MockModule->new('BOM::Product::Contract::Strike');
$mock_barrier->mock('as_absolute', sub { 100.151 });

subtest 'match/mismatch condition for commission adjustment' => sub {
    clear_config();
    $qc->save_config(
        'commission',
        {
            name            => 'test1',
            currency_symbol => 'EUR',
            start_time      => $now->epoch,
            end_time        => $now->plus_time_interval('1h')->epoch,
            OTM_max         => 0.45
        });
    $qc->save_config(
        'commission',
        {
            name              => 'test2',
            underlying_symbol => 'frxUSDJPY',
            currency_symbol   => 'AUD',
            start_time        => $now->epoch,
            end_time          => $now->plus_time_interval('1h')->epoch,
            OTM_max           => 0.25
        });

    $args->{underlying} = 'frxGBPJPY';
    my $c = produce_contract($args);
    is $c->barrier_tier, 'OTM_max', 'barrier tier is OTM_max';
    is $c->pricing_engine->event_markup->amount, 0, 'zero markup if no matching config';
    $args->{underlying} = 'frxUSDJPY';
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0.25, '0.25 markup for matching both underlying & contract type config';
    $args->{underlying} = 'frxEURJPY';
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0.45, '0.45 markup for matching both underlying & contract type config';
};

subtest 'timeframe' => sub {
    $args->{date_start} = $args->{date_pricing} = $now->plus_time_interval('1h1s');
    my $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0, 'zero markup if contract start or expiry is not in timeframe';
    $args->{date_start} = $args->{date_pricing} = $now->minus_time_interval('1h1s');
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0, 'zero markup if contract start or expiry is not in timeframe';
    $args->{date_start} = $args->{date_pricing} = $now->minus_time_interval('2h1s');
    $args->{duration}   = '3h1s';
    $c                  = produce_contract($args);
    ok $c->pricing_engine->event_markup->amount == 0, 'has no markup if contract spans the timeframe';
};

subtest 'barrier tier' => sub {
    clear_config();
    $qc->save_config(
        'commission',
        {
            name            => 'test1',
            currency_symbol => 'USD',
            start_time      => $now->epoch,
            end_time        => $now->plus_time_interval('1h')->epoch,
            ITM_1           => 0.1,
            ITM_2           => 0.2,
            ITM_3           => 0.3,
            ATM             => 0.01,
            OTM_max         => 0.45,
            ITM_max         => 0.35
        });
    $args->{date_start}           = $args->{date_pricing} = $now;
    $args->{trading_period_start} = $now->epoch;

    my @test_cases = (
        # ITM CALL with 3 barriers on each side
        [0.001, 'frxUSDJPY', 'CALLE', 100, 99.951, 'ITM_1',   0.1],
        [0.001, 'frxUSDJPY', 'CALLE', 100, 99.949, 'ITM_2',   0.2],
        [0.001, 'frxUSDJPY', 'CALLE', 100, 99.899, 'ITM_3',   0.3],
        [0.001, 'frxUSDJPY', 'CALLE', 100, 99.849, 'ITM_max', 0.35],
        # ITM CALL with 2 barriers on each side
        [0.00001, 'frxAUDUSD', 'CALLE', 100, 99.99951, 'ITM_1',   0.1],
        [0.00001, 'frxAUDUSD', 'CALLE', 100, 99.99949, 'ITM_2',   0.2],
        [0.00001, 'frxAUDUSD', 'CALLE', 100, 99.99899, 'ITM_max', 0.35],
        [0.00001, 'frxAUDUSD', 'CALLE', 100, 99.99849, 'ITM_max', 0.35],
        # ITM PUT. 0 commission because it is not defined
        [0.001, 'frxUSDJPY', 'PUTE', 99.950, 100,    'ITM_1', 0.1],
        [0.001, 'frxUSDJPY', 'PUTE', 100,    99.950, 'OTM_1', 0],
        # ITM PUT. max still applies
        [0.001, 'frxUSDJPY', 'PUTE', 99.849, 100,    'ITM_max', 0.35],
        [0.001, 'frxUSDJPY', 'PUTE', 100,    99.849, 'OTM_max', 0.45],
        # OTM PUT
        [0.001, 'frxUSDJPY', 'PUTE', 100, 99.951, 'OTM_1', 0],
        [0.001, 'frxUSDJPY', 'PUTE', 100, 99.949, 'OTM_2', 0],
        [0.001, 'frxUSDJPY', 'PUTE', 100, 99.899, 'OTM_3', 0],
    );

    foreach my $test (@test_cases) {
        $mock_underlying->mock('pip_size', sub { $test->[0] });
        $args->{underlying}   = $test->[1];
        $args->{bet_type}     = $test->[2];
        $args->{product_type} = 'multi_barrier';
        $mock_contract->mock('current_spot', sub { $test->[3] });
        $mock_barrier->mock('as_absolute', sub { $test->[4] });
        my $c = produce_contract($args);
        is $c->barrier_tier, $test->[5],
            'barrier tier is ' . $c->barrier_tier . ' for point difference ' . ($test->[3] - $test->[4]) . " on $args->{underlying}";
        is $c->pricing_engine->event_markup->amount, $test->[6], 'event markup is ' . $c->pricing_engine->event_markup->amount;
    }
    # ATM
    $args->{product_type} = 'basic';
    my $c = produce_contract(+{%$args, barrier => 'S0P'});
    ok $c->is_atm_bet, 'is atm';
    is $c->barrier_tier, 'ATM', 'barrier tier is ATM';
    is $c->pricing_engine->event_markup->amount, 0.01, '0.01 of commission applied to ATM';
};

subtest 'touch/notouch' => sub {
    clear_config();
    $qc->save_config(
        'commission',
        {
            name            => 'test1',
            currency_symbol => 'USD',
            start_time      => $now->epoch,
            end_time        => $now->plus_time_interval('1h')->epoch,
            OTM_1           => 0.1,
            OTM_2           => 0.2,
            OTM_3           => 0.3,
        });
    my @test_cases = (
        # OTM ONETOUCH
        [0.001, 'frxUSDJPY', 'ONETOUCH', 100,    99.951, 'OTM_1', 0.1],
        [0.001, 'frxUSDJPY', 'ONETOUCH', 100,    99.949, 'OTM_2', 0.2],
        [0.001, 'frxUSDJPY', 'ONETOUCH', 100,    99.899, 'OTM_3', 0.3],
        [0.001, 'frxUSDJPY', 'ONETOUCH', 99.951, 100,    'OTM_1', 0.1],
        [0.001, 'frxUSDJPY', 'ONETOUCH', 99.949, 100,    'OTM_2', 0.2],
        [0.001, 'frxUSDJPY', 'ONETOUCH', 99.899, 100,    'OTM_3', 0.3],
    );

    foreach my $test (@test_cases) {
        $mock_underlying->mock('pip_size', sub { $test->[0] });
        $args->{underlying} = $test->[1];
        $args->{bet_type}   = $test->[2];
        $mock_contract->mock('current_spot', sub { $test->[3] });
        $mock_barrier->mock('as_absolute', sub { $test->[4] });
        my $c = produce_contract({
            %$args,
            product_type         => 'multi_barrier',
            trading_period_start => time
        });
        is $c->barrier_tier, $test->[5],
            'barrier tier is ' . $c->barrier_tier . ' for point difference ' . ($test->[3] - $test->[4]) . " on $args->{underlying}";
        is $c->pricing_engine->event_markup->amount, $test->[6], 'event markup is ' . $c->pricing_engine->event_markup->amount;
    }
};

subtest 'bias long' => sub {
    $mock_underlying->mock('pip_size', sub { 0.001 });
    $mock_contract->mock('current_spot', sub { 100 });
    $mock_barrier->mock('as_absolute', sub { 100.151 });
    clear_config();
    $qc->save_config(
        'commission',
        {
            name            => 'test1',
            currency_symbol => 'AUD',
            start_time      => $now->epoch,
            end_time        => $now->plus_time_interval('1h')->epoch,
            bias            => 'long',
            ITM_max         => 0.55,
            OTM_max         => 0.5,
        });
    $args->{underlying}   = 'frxAUDJPY';
    $args->{bet_type}     = 'CALLE';
    $args->{product_type} = 'multi_barrier';
    note('bias is set to long on AUD');
    my $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0.5, '0.5 event markup for CALLE-frxAUDJPY';
    $args->{bet_type}     = 'PUT';
    $args->{product_type} = 'basic';
    $c                    = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0, '0 event markup for PUT-frxAUDJPY';
    $mock_underlying->mock('pip_size', sub { 0.00001 });
    $mock_contract->mock('current_spot', sub { 100 });
    $mock_barrier->mock('as_absolute', sub { 100.00151 });
    $args->{underlying} = 'frxEURAUD';
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0.55, '0.55 event markup for PUT-frxEURAUD';
    $args->{bet_type} = 'CALL';
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0, '0 event markup for CALL-frxEURAUD';
    $qc->save_config(
        'commission',
        {
            name            => 'test2',
            currency_symbol => 'USD',
            start_time      => $now->epoch,
            end_time        => $now->plus_time_interval('1h')->epoch,
            bias            => 'short',
            ITM_max         => 0.66,
            OTM_max         => 0.6,
        });

    $mock_underlying->mock('pip_size', sub { 0.001 });
    $mock_contract->mock('current_spot', sub { 100 });
    $mock_barrier->mock('as_absolute', sub { 100.151 });
    $args->{underlying}   = 'frxUSDJPY';
    $args->{bet_type}     = 'CALLE';
    $args->{product_type} = 'multi_barrier';
    note('bias is set to short on USD');
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0, '0 event markup for CALLE-frxUSDJPY';
    $args->{bet_type}     = 'PUT';
    $args->{product_type} = 'basic';
    $c                    = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0.66, '0.66 event markup for PUT-frxUSDJPY';
    $mock_underlying->mock('pip_size', sub { 0.00001 });
    $mock_contract->mock('current_spot', sub { 100 });
    $mock_barrier->mock('as_absolute', sub { 100.00151 });
    $args->{underlying} = 'frxEURUSD';
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0, '0 event markup for PUT-frxEURUSD';
    $args->{bet_type} = 'CALL';
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0.6, '0.6 event markup for CALL-frxEURUSD';

    $args->{underlying} = 'frxAUDUSD';
    $args->{bet_type}   = 'PUT';
    $c                  = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0, '0 event markup for PUT-frxAUDUSD';
    $args->{bet_type} = 'CALL';
    $c = produce_contract($args);
    is $c->pricing_engine->event_markup->amount, 0.6, '0.6 event markup for CALL-frxAUDUSD';

};

sub clear_config {
    $qc->chronicle_writer->set('quants_config', 'commission', {}, $now->minus_time_interval('4h'));
}
done_testing();
