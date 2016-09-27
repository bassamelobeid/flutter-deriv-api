#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db;
use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);

my $now = Date::Utility->new('2016-09-27 10:00:00');

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
    underlying      => 'frxUSDJPY',
    bet_type        => 'CALL',
    duration        => '15m',
    barrier         => 'S10P',
    current_tick    => $fake_tick,
    currency        => 'USD',
    payout          => 10,
    landing_company => 'japan',
    date_start      => $now,
    date_pricing    => $now,
};

subtest 'non atm short term kurtosis markup' => sub {
    my $c = produce_contract($bet_params);
    is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'intraday forex engine.';
    is $c->pricing_engine->risk_markup->peek_amount('short_term_kurtosis_risk_markup'), 0.01, 'kurtosis risk markup of 0.01 for a 15m contract.';
    $bet_params->{duration} = '15m1s';
    $c = produce_contract($bet_params);
    is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'intraday forex engine.';
    ok !$c->pricing_engine->risk_markup->peek_amount('short_term_kurtosis_risk_markup'), 'no kurtosis risk markup for a 15m1s contract.';
    $bet_params->{duration} = '14m59s';
    $c = produce_contract($bet_params);
    is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'intraday forex engine.';
    is $c->pricing_engine->risk_markup->peek_amount('short_term_kurtosis_risk_markup'), 0.0101666666666667,
        'kurtosis risk markup of 0.0101666666666667 for a 14m59s contract.';
    $bet_params->{duration} = '2m';
    $c = produce_contract($bet_params);
    is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'intraday forex engine.';
    is $c->pricing_engine->risk_markup->peek_amount('short_term_kurtosis_risk_markup'), 0.14, 'kurtosis risk markup of 0.14 for a 2m contract.';
};

subtest 'atm short term kurtosis markup' => sub {
    $bet_params->{barrier}  = 'S0P';
    $bet_params->{duration} = '15m';
    delete $bet_params->{landing_company};
    my $c = produce_contract($bet_params);
    is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'intraday forex engine.';
    ok !$c->pricing_engine->risk_markup->peek_amount('short_term_kurtosis_risk_markup'), 'no kurtosis risk markup for a 15m1s contract.';
};

done_testing();
