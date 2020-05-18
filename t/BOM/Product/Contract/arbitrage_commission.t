#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Test::Exception;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);

my $mocked_decimate = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked_decimate->mock(
    'get',
    sub {
        [map { {epoch => $_, decimate_epoch => $_, quote => 100 + 0.005 * $_} } (0 .. 80)];
    });

my $now = Date::Utility->new('2018-09-18 13:57:00');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        recorded_date => $now,
        symbol        => $_,
    }) for qw( USD JPY-USD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now
    }) for ('frxUSDJPY');

my $current_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch,
    quote      => 100.3
});

subtest 'arbitrage markup on intraday fx' => sub {
    my $args = {
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        date_start   => $now,
        date_pricing => $now,
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 100,
        duration     => '4h59m',
        current_tick => $current_tick,
    };
    my $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';
    is $c->pricing_engine->risk_markup->peek_amount('model_arbitrage'), 0.03, '3% of model arbitrage is charged for 4h59m on CALL';

    $args->{bet_type} = 'PUT';
    $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';
    is $c->pricing_engine->risk_markup->peek_amount('model_arbitrage'), 0.03, '3% of model arbitrage is charged for 4h59m on PUT';

    $args->{duration} = '4h58m59s';
    $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';
    ok !$c->pricing_engine->risk_markup->peek_amount('model_arbitrage'), '3% of model arbitrage is not charged for 4h58m59s on PUT';

    $args->{bet_type} = 'CALL';
    $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';
    ok !$c->pricing_engine->risk_markup->peek_amount('model_arbitrage'), '3% of model arbitrage is not charged for 4h58m59s on CALL';
};

subtest 'arbitrage markup on slope fx' => sub {
    my $args = {
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        date_start   => $now,
        date_pricing => $now,
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 100,
        duration     => '5h1m',
        current_tick => $current_tick,
    };
    my $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';
    $c->pricing_engine->_risk_markup;
    is $c->pricing_engine->debug_info->{risk_markup}{parameters}{model_arbitrage_markup}, 0.03, '3% of model arbitrage is charged for 5h1m on CALL';

    $args->{bet_type} = 'PUT';
    $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';
    $c->pricing_engine->_risk_markup;
    is $c->pricing_engine->debug_info->{risk_markup}{parameters}{model_arbitrage_markup}, 0.03, '3% of model arbitrage is charged for 5h1m on PUT';

    $args->{duration} = '5h1m1s';
    $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';
    $c->pricing_engine->_risk_markup;
    ok !$c->pricing_engine->debug_info->{risk_markup}{parameters}{model_arbitrage_markup}, '3% of model arbitrage is not charged for 5h1m1s on PUT';

    $args->{bet_type} = 'CALL';
    $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';
    $c->pricing_engine->_risk_markup;
    ok !$c->pricing_engine->debug_info->{risk_markup}{parameters}{model_arbitrage_markup}, '3% of model arbitrage is not charged for 5h1m1s on CALL';
};

done_testing();
