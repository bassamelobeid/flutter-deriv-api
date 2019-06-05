#!/usr/bin/perl

use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Product::ContractFactory qw(produce_contract);
use Test::More;
use Test::MockModule;
use Test::Warn;
use Date::Utility;

subtest 'monday mornings intraday' => sub {
    my $mocked = Test::MockModule->new('BOM::Market::DataDecimate');
    my $dp     = Date::Utility->new('2017-06-13 00:19:59');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $dp});
    my $args = {
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        date_start   => $dp,
        date_pricing => $dp,
        duration     => '15m',
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 100,
    };
    my $c = produce_contract($args);
    isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';
    my $vol = $c->pricing_vol;
    is $c->pricing_vol, 0.083301434838787, 'seasonalized 8% vol';
    is $c->empirical_volsurface->validation_error, 'Insufficient ticks to calculate historical volatility.',
        'error at first 20 minutes on a tuesday morning';
    ok $c->primary_validation_error, 'primary validation error set';
    is $c->primary_validation_error->message, 'Insufficient ticks to calculate historical volatility.', 'error message checked';
    $dp = Date::Utility->new('2017-06-12 00:19:59');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $dp});
    $args->{date_pricing} = $args->{date_start} = $dp;
    $c = produce_contract($args);
    is $c->pricing_vol, 0.083301434838787, 'seasonalized 8% vol on monday morning in the first 20 minutes';
    ok !$c->empirical_volsurface->validation_error, 'no error on monday morning';
    $dp = Date::Utility->new('2017-06-12 00:20:01');
    $args->{date_pricing} = $args->{date_start} = $dp;
    $c = produce_contract($args);
    is $c->pricing_vol, 0.0832856076621925, 'seasonalized 8% vol';
    is $c->empirical_volsurface->validation_error, 'Insufficient ticks to calculate historical volatility.',
        'warn if historical tick not found after first 20 minutes of a monday morning';
    ok $c->primary_validation_error, 'primary validation error set';
    is $c->primary_validation_error->message, 'Insufficient ticks to calculate historical volatility.', 'error message checked';
    $mocked->mock(
        'get',
        sub {
            [map { {epoch => $_, decimate_epoch => $_, quote => 100 + 0.005 * $_} } (0 .. 80)];
        });
    $c = produce_contract($args);
    ok $c->pricing_vol, 'no warnings';
    ok !$c->empirical_volsurface->validation_error, 'no error if we have enough ticks';
};

done_testing();
