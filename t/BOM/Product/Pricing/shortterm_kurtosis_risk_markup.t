#!/usr/bin/perl

use strict;
use warnings;

use Date::Utility;

use Test::More;
use Test::Warnings;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory qw(produce_contract);
use Test::MockModule;

my $mocked = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked->mock(
    'get',
    sub {
        [map { {epoch => $_, decimate_epoch => $_, quote => 100 + 0.005 * $_} } (0 .. 80)];
    });
initialize_realtime_ticks_db;

my $now = Date::Utility->new('2016-09-27 10:00:00');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(USD JPY JPY-USD);
my $fake_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    quote      => 100,
    epoch      => $now->epoch,
});

my $bet_params = {
    underlying           => 'frxUSDJPY',
    bet_type             => 'CALL',
    duration             => '15m',
    barrier              => 'S10P',
    current_tick         => $fake_tick,
    currency             => 'USD',
    payout               => 10,
    product_type         => 'multi_barrier',
    trading_period_start => time,
    date_start           => $now,
    date_pricing         => $now,
};

subtest 'non atm short term kurtosis markup' => sub {
    my $c = produce_contract($bet_params);
    is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'intraday forex engine.';
    is $c->pricing_engine->risk_markup->peek_amount('short_term_kurtosis_risk_markup'), 0, 'kurtosis risk markup of 0.01 for a 15m contract.';
    $bet_params->{duration} = '15m1s';
    $c = produce_contract($bet_params);
    is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'intraday forex engine.';
    ok !$c->pricing_engine->risk_markup->peek_amount('short_term_kurtosis_risk_markup'), 'no kurtosis risk markup for a 15m1s contract.';
    $bet_params->{duration} = '14m59s';
    $c = produce_contract($bet_params);
    is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'intraday forex engine.';
    is $c->pricing_engine->risk_markup->peek_amount('short_term_kurtosis_risk_markup'), 0.000166666666666676,
        'kurtosis risk markup of 0.0101666666666667 for a 14m59s contract.';
    $bet_params->{duration} = '2m';
    $c = produce_contract($bet_params);
    is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'intraday forex engine.';
    is $c->pricing_engine->risk_markup->peek_amount('short_term_kurtosis_risk_markup'), 0.13, 'kurtosis risk markup of 0.13 for a 2m contract.';
};

subtest 'atm short term kurtosis markup' => sub {
    $bet_params->{barrier}  = 'S0P';
    $bet_params->{duration} = '15m';
    delete $bet_params->{product_type};
    my $c = produce_contract($bet_params);
    is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'intraday forex engine.';
    ok !$c->pricing_engine->risk_markup->peek_amount('short_term_kurtosis_risk_markup'), 'no kurtosis risk markup for a 15m1s contract.';
};

done_testing();
