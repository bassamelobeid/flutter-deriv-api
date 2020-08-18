#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Test::MockModule;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);
use Cache::RedisDB;
BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;

Cache::RedisDB->flushall;
initialize_realtime_ticks_db();

my $mocked_decimate = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked_decimate->mock(
    'get',
    sub {
        [map { {epoch => $_, decimate_epoch => $_, quote => 100 + 0.005 * $_} } (0 .. 80)];
    });
my $now = Date::Utility->new('2016-09-28 10:15:00');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});

my $underlying_symbol = 'frxAUDJPY';
BOM::Test::Data::Utility::UnitTestMarketData::create_predefined_parameters_for($underlying_symbol, $now);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $underlying_symbol,
        recorded_date => $now
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(AUD USD JPY JPY-USD AUD-JPY);

subtest 'predefined_contracts' => sub {
    my $bet_params = {
        underlying   => $underlying_symbol,
        bet_type     => 'CALL',
        date_start   => $now,
        date_pricing => $now,
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 1000,
        duration     => '15m',
    };
    my $c = produce_contract($bet_params);
    ok !$c->can('predefined_contracts'), 'no predefined_contracts for basic product_type';
    ok $c->is_valid_to_buy, 'valid to buy.';

    $bet_params->{product_type}         = 'multi_barrier';
    $bet_params->{trading_period_start} = $now->epoch;
    $bet_params->{bet_type}             = 'CALLE';
    $bet_params->{barrier}              = '100.010';
    $c                                  = produce_contract($bet_params);
    ok !%{$c->predefined_contracts}, 'has predefined_contracts for multi_barrier';
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is_deeply($c->primary_validation_error->message_to_client, ['Invalid expiry time.']);
    note('sets predefined_contracts with valid expiry time.');
    delete $bet_params->{duration};
    $bet_params->{date_expiry}  = $now->plus_time_interval('2h');
    $bet_params->{date_start}   = $bet_params->{date_pricing} = $now->plus_time_interval('15m1s');
    $bet_params->{barrier}      = 100.050;
    $bet_params->{current_tick} = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => $underlying_symbol,
        epoch      => $bet_params->{date_start}->epoch,
        quote      => 100,
    });
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    is scalar(@{$c->predefined_contracts->{available_barriers}}), 5,
        'only 5 barriers available even if expiry of 2-hour trading window overlaps with 6-hour trading window';

    $c = produce_contract(
        +{
            %$bet_params,
            predefined_contracts => {
                available_barriers => [100.050],
                expired_barriers   => [100.050]}});
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is_deeply($c->primary_validation_error->message_to_client, ['Invalid barrier.']);

    $bet_params->{bet_type}     = 'EXPIRYMISS';
    $bet_params->{high_barrier} = '101';
    $bet_params->{low_barrier}  = '99';
    $c                          = produce_contract(+{%$bet_params, predefined_contracts => {available_barriers => [['99.100', '100.000']]}});
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is_deeply($c->primary_validation_error->message_to_client, ['Invalid barrier.']);
    $c = produce_contract({
        %$bet_params,
        payout   => 1000,
        currency => 'JPY'
    });
    $c = produce_contract(+{%$bet_params, predefined_contracts => {available_barriers => [['99.000', '101.000']]}});
    ok $c->is_valid_to_buy, 'valid to buy';
    $c = produce_contract(
        +{
            %$bet_params,
            predefined_contracts => {
                available_barriers => [['99.000', '101.000']],
                expired_barriers   => [['99.000', '101.000']]}});
    ok !$c->is_valid_to_buy, 'not valid to buy if barrier expired';
};

done_testing();
