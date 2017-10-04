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
    my $vol;
    warning_like {is $c->pricing_vol, 0.104126793548484, 'seasonalized 10% vol' } qr/Insufficient ticks to calculate historical volatility/, 'warns';
    is $c->empirical_volsurface->validation_error, 'Insufficient ticks to calculate historical volatility.',
        'error at first 20 minutes on a tuesday morning';
    $dp = Date::Utility->new('2017-06-12 00:19:59');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $dp});
    $args->{date_pricing} = $args->{date_start} = $dp;
    $c = produce_contract($args);
    is $c->pricing_vol, 0.104126793548484, 'seasonalized 10% vol on monday morning in the first 20 minutes';
    ok !$c->empirical_volsurface->validation_error, 'no error on monday morning';
    $dp = Date::Utility->new('2017-06-12 00:20:01');
    $args->{date_pricing} = $args->{date_start} = $dp;
    $c = produce_contract($args);
    warning_like { is $c->pricing_vol, 0.10410700957774, 'seasonalized 10% vol'} qr/Insufficient ticks to calculate historical volatility/, 'warns';
    is $c->empirical_volsurface->validation_error, 'Insufficient ticks to calculate historical volatility.',
        'warn if historical tick not found after first 20 minutes of a monday morning';
    $mocked->mock(
        'get',
        sub {
            [map { {epoch => $_, decimate_epoch => $_, quote => 100 + rand(0.005)} } (0 .. 80)];
        });
    $c = produce_contract($args);
    ok $c->pricing_vol, 'no warnings';
    ok !$c->empirical_volsurface->validation_error, 'no error if we have enough ticks';
};

done_testing();
