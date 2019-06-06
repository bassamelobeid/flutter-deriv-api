#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Test::Warnings qw/warning/;
use Test::MockModule;
use Date::Utility;
use Math::Util::CalculatedValue::Validatable;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

initialize_realtime_ticks_db();

my $inefficient_time = Date::Utility->new('2016-10-06 20:00:00');
my $efficient_time   = $inefficient_time->minus_time_interval('1s');
note("America is in DST on " . $inefficient_time->date);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $efficient_time});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $efficient_time
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $efficient_time
    }) for qw(USD JPY JPY-USD);
my $cv = Math::Util::CalculatedValue::Validatable->new({
    name        => 'fake',
    base_amount => 0,
    description => 'test',
    set_by      => 'tester'
});
my $mock_intraday = Test::MockModule->new('BOM::Product::Pricing::Engine::Intraday::Forex');

#$mock_intraday->mock('intraday_delta_correction', sub { $cv });
$mock_intraday->mock('intraday_vega_correction', sub { $cv });

subtest 'inefficient craziness' => sub {
    my $bet_params = {
        underlying   => 'frxUSDJPY',
        bet_type     => 'CALL',
        barrier      => 'S0P',
        date_start   => $inefficient_time,
        date_pricing => $inefficient_time,
        duration     => '5m',
        currency     => 'USD',
        payout       => 10,
    };
    my $c = produce_contract($bet_params);
    my $res;
    warning { $res = $c->pricing_engine->risk_markup->peek_amount('intraday_eod_markup') }, qr/No basis tick for/;
    is $res, 0.05, 'eod markup added for ATM';
    $bet_params->{duration}   = '15m';
    $bet_params->{underlying} = 'R_100';
    $c                        = produce_contract($bet_params);
    warning { $res = $c->ask_probability->amount }, qr/No basis tick for/;
    ok $res < 0.7, 'ask probability is less than 0.7 for R_100';
    $bet_params->{underlying} = 'frxUSDJPY';
    $bet_params->{barrier}    = 'S5P';
    $c                        = produce_contract($bet_params);
    warning { $res = $c->ask_probability->amount }, qr/No basis tick for/;
    ok $res < 0.7, 'ask probability is less than 0.7 for USDJPY non ATM';
    warning { $res = $c->pricing_engine->risk_markup->peek_amount('intraday_eod_markup') }, qr/No basis tick for/;
    is $res, 0.1, '10% eod markup added for non ATM';
    $bet_params->{barrier}    = 'S0P';
    $bet_params->{date_start} = $bet_params->{date_pricing} = $efficient_time;
    $c                        = produce_contract($bet_params);
    warning { $res = $c->ask_probability->amount }, qr/No basis tick for/;
    ok $res < 0.7, 'ask probability is less than 0.7 1 second before inefficient period';
    $bet_params->{barrier} = 'S5P';
    $c = produce_contract($bet_params);
    warning { $res = $c->pricing_engine->risk_markup->peek_amount('intraday_eod_markup') }, qr/No basis tick for/;
    ok !$res, '10% eod markup not added 1 second before inefficient period';
};

subtest 'payout limit' => sub {
    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $inefficient_time->epoch,
        quote      => 100
    });
    my $bet_params = {
        underlying   => 'frxUSDJPY',
        bet_type     => 'CALL',
        barrier      => 'S0P',
        date_start   => $inefficient_time,
        date_pricing => $inefficient_time,
        duration     => '5m',
        currency     => 'USD',
        payout       => 200,
        current_tick => $tick,
        pricing_vol  => 0.1
    };
    my $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy at 200';
    $bet_params->{payout} = 201;
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'invalid to buy at 201';
    like($c->primary_validation_error->message, qr/payout amount outside acceptable range/, 'throws error');
};

done_testing();
