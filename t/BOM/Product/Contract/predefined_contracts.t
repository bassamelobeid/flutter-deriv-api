#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::MockModule;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);

my $now = Date::Utility->new('2016-09-28 10:00:00');
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

my $mocked = Test::MockModule->new('BOM::Market::AggTicks');
$mocked->mock(
    'retrieve',
    sub {
        [map { {epoch => $_, quote => 100, symbol => 'frxUSDJPY'} } (0 .. 20)];
    });

subtest 'predefined_contracts' => sub {
    my $fake_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $now->epoch,
        quote      => 100,
    });
    my $bet_params = {
        underlying   => 'frxUSDJPY',
        bet_type     => 'CALL',
        date_start   => $now,
        date_pricing => $now,
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 10,
        duration     => '15m',
        current_tick => $fake_tick,
    };
    my $c = produce_contract($bet_params);
    is $c->landing_company, 'costarica', 'landing company is costarica';
    ok !%{$c->predefined_contracts}, 'no predefined_contracts for costarica';
    ok $c->is_valid_to_buy, 'valid to buy.';

    $bet_params->{landing_company} = 'japan';
    $bet_params->{bet_type}        = 'CALLE';
    $bet_params->{barrier}         = 'S10P';
    $c                             = produce_contract($bet_params);
    is $c->landing_company, 'japan', 'landing company is japan';
    ok %{$c->predefined_contracts}, 'has predefined_contracts for japan';
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like($c->primary_validation_error->message_to_client, qr/Invalid expiry time/, 'throws error');
    note('sets predefined_contracts with valid expiry time.');
    my $expiry_epoch = $now->plus_time_interval('1h')->epoch;
    $bet_params->{predefined_contracts} = {
        $expiry_epoch => {
            date_start         => $now->plus_time_interval('15m')->epoch,
            available_barriers => ['100.010'],
        }};
    delete $bet_params->{duration};
    $bet_params->{date_expiry} = $expiry_epoch;
    $c = produce_contract($bet_params);
    ok $c->date_expiry->epoch == $expiry_epoch, 'contract expiry properly set';
    ok exists $c->predefined_contracts->{$expiry_epoch}, 'predefined contract\'s expiry properly set';
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like($c->primary_validation_error->message_to_client, qr/Invalid start time/, 'throws error');
    $bet_params->{date_start} = $bet_params->{date_pricing} = $now->plus_time_interval('15m1s');
    $bet_params->{current_tick} = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $bet_params->{date_start}->epoch,
        quote      => 100,
    });
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
};

done_testing();
