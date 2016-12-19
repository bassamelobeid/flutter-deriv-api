#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::MockModule;

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;
use Math::Util::CalculatedValue::Validatable;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

my $inactive_time             = Date::Utility->new('2016-10-06 21:00:00');
my $inefficient_inactive_time = Date::Utility->new('2016-10-06 22:00:00');
my $active_time               = $inactive_time->minus_time_interval('1s');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $active_time
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $active_time
    }) for qw(USD JPY JPY-USD);
my $cv = Math::Util::CalculatedValue::Validatable->new({
    name        => 'fake',
    base_amount => 0,
    description => 'test',
    set_by      => 'tester'
});
#<<<<<<< HEAD
#=======
#my $mock = Test::MockModule->new('BOM::Market::AggTicks');
#$mock->mock(
#    'retrieve',
#    sub {
#        [map { {epoch => $_, quote => 10} } (0 .. 5)];
#    });
#>>>>>>> 294205b0423e000be166f8cae4735c0968f8eba1
my $mock_intraday = Test::MockModule->new('BOM::Product::Pricing::Engine::Intraday::Forex');

$mock_intraday->mock('intraday_delta_correction', sub { $cv });
$mock_intraday->mock('intraday_vega_correction',  sub { $cv });

subtest 'inactive check' => sub {
    my $bet_params = {
        underlying   => 'frxUSDJPY',
        bet_type     => 'CALL',
        barrier      => 'S0P',
        date_start   => $inactive_time,
        date_pricing => $inactive_time,
        duration     => '5m',
        currency     => 'USD',
        payout       => 10,
    };
    my $c = produce_contract($bet_params);
    ok $c->pricing_engine->risk_markup->peek_amount('intraday_eod_markup'), 'eod markup added for ATM';
    is $c->pricing_engine->risk_markup->peek_amount('intraday_inactive_markup'), 0.05, '5% inactive markup added for ATM';

    $bet_params->{barrier}  = 'S5P';
    $bet_params->{duration} = '15m';
    $c                      = produce_contract($bet_params);
    ok !$c->pricing_engine->risk_markup->peek_amount('intraday_inactive_markup'), 'inactive markup not added for non ATM';

    $bet_params->{date_start} = $bet_params->{date_pricing} = $active_time;
    $bet_params->{barrier}    = 'S0P';
    $c                        = produce_contract($bet_params);
    ok !$c->pricing_engine->risk_markup->peek_amount('intraday_inactive_markup'), 'inactive markup not added for active time ATM';

    $bet_params->{barrier} = 'S5P';
    $c = produce_contract($bet_params);
    is $c->pricing_engine->risk_markup->peek_amount('intraday_eod_markup'), 0.1, 'for non-ATM, inefficient markup is still added in active period';
    ok !$c->pricing_engine->risk_markup->peek_amount('intraday_inactive_markup'), 'inactive markup not added for efficient time non-ATM';

    $bet_params->{date_start} = $bet_params->{date_pricing} = $inefficient_inactive_time;
    $bet_params->{barrier}    = 'S0P';
    $c                        = produce_contract($bet_params);
    is $c->pricing_engine->risk_markup->peek_amount('intraday_eod_markup'), 0.05, 'eod markup in inactive-and-inefficient period - ATM';
    is $c->pricing_engine->risk_markup->peek_amount('intraday_inactive_markup'), 0.05,
        'inactive markup added in inactive-and-inefficient period - ATM';

    $bet_params->{barrier} = 'S5P';
    $c = produce_contract($bet_params);
    is $c->pricing_engine->risk_markup->peek_amount('intraday_eod_markup'), 0.1, 'eod markup in inactive-and-inefficient period for non-ATM';
    ok !$c->pricing_engine->risk_markup->peek_amount('intraday_inactive_markup'), 'inactive markup not added for non-ATM';
};

done_testing();
