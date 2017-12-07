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
my $now = Date::Utility->new('2016-09-28 10:00:00');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $_,
    }) for ($now->minus_time_interval('400d')->epoch, $now->epoch, $now->plus_time_interval('1s')->epoch);

BOM::Test::Data::Utility::UnitTestMarketData::create_trading_periods('frxUSDJPY', $now);
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

subtest 'predefined_contracts' => sub {
    my $bet_params = {
        underlying   => 'frxUSDJPY',
        bet_type     => 'CALL',
        date_start   => $now,
        date_pricing => $now,
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 10,
        duration     => '15m',
    };
    my $c = produce_contract($bet_params);
    ok !$c->can('predefined_contracts'), 'no predefined_contracts for costarica';
    ok $c->is_valid_to_buy, 'valid to buy.';

    $bet_params->{product_type} = 'multibarrier';
    $bet_params->{bet_type}     = 'CALLE';
    $bet_params->{barrier}      = '100.010';
    $c                          = produce_contract($bet_params);
    ok %{$c->predefined_contracts}, 'has predefined_contracts for japan';
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is_deeply($c->primary_validation_error->message_to_client, ['Invalid expiry time.']);
    note('sets predefined_contracts with valid expiry time.');
    my $expiry_epoch = $now->plus_time_interval('1h')->epoch;
    delete $bet_params->{duration};
    $bet_params->{date_expiry}  = $expiry_epoch;
    $bet_params->{date_start}   = $bet_params->{date_pricing} = $now->plus_time_interval('15m1s');
    $bet_params->{current_tick} = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $bet_params->{date_start}->epoch,
        quote      => 100,
    });
    $c = produce_contract($bet_params);
    $c->predefined_contracts({
            $expiry_epoch => {
                date_start         => $now->plus_time_interval('15m')->epoch,
                available_barriers => ['100.010'],
            }});
    ok $c->is_valid_to_buy, 'valid to buy';
    $c = produce_contract($bet_params);
    $c->predefined_contracts({
            $expiry_epoch => {
                available_barriers => ['100.010'],
                expired_barriers   => ['100.010'],
            }});
    ok !$c->is_valid_to_buy, 'not valid to buy if barrier expired';
    is_deeply($c->primary_validation_error->message_to_client, ['Invalid barrier.']);

    $bet_params->{bet_type}     = 'EXPIRYMISS';
    $bet_params->{high_barrier} = '101';
    $bet_params->{low_barrier}  = '99';
    $c                          = produce_contract($bet_params);
    $c->predefined_contracts({
            $expiry_epoch => {
                available_barriers => [['99.100', '100.000']],
            }});
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is_deeply($c->primary_validation_error->message_to_client, ['Invalid barrier.']);
    $c = produce_contract({
        %$bet_params,
        payout   => 1000,
        currency => 'JPY'
    });
    $c->predefined_contracts({
            $expiry_epoch => {
                available_barriers => [['99.000', '101.000']],
            }});
    ok $c->is_valid_to_buy, 'valid to buy';
    $c = produce_contract($bet_params);
    $c->predefined_contracts({
            $expiry_epoch => {
                available_barriers => [['99.000', '101.000']],
                expired_barriers   => [['99.000', '101.000']],
            }});
    ok !$c->is_valid_to_buy, 'not valid to buy if barrier expired';
    is_deeply($c->primary_validation_error->message_to_client, ['Invalid barrier.']);
};

done_testing();
