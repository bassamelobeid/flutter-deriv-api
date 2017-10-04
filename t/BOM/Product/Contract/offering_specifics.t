#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Test::MockModule;
use LandingCompany::Offerings qw(reinitialise_offerings);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

my $mocked_decimate = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked_decimate->mock(
    'get',
    sub {
        [map { {epoch => $_, decimate_epoch => $_, quote => 100 + 0.005*$_} } (0 .. 80)];
    });
my $mock = Test::MockModule->new('BOM::Product::Contract::PredefinedParameters');
$mock->mock('get_trading_periods', sub { [] });
use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;
use Cache::RedisDB;

reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);

my $now = Date::Utility->new('2016-09-22');
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
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $_->epoch,
        quote      => 100
    }) for ($now->minus_time_interval('100d'), $now);

my $bet_params = {
    underlying   => 'frxUSDJPY',
    bet_type     => 'CALL',
    date_start   => $now,
    date_pricing => $now,
    duration     => '2m',
    barrier      => 'S11P',
    currency     => 'USD',
    payout       => 10,
};
subtest '2-minute non ATM callput' => sub {
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/Intraday duration not acceptable/, 'throws error duration not accepted.';
    $c = produce_contract({%$bet_params, landing_company => 'japan'});
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/barrier should be absolute/, 'throws error barrier type not correct';
    $c = produce_contract({
        %$bet_params,
        landing_company => 'japan',
        barrier         => '101.1'
    });
    ok $c->is_valid_to_buy, 'valid to buy';
    note('sets duration to 1m59s.');
    $c = produce_contract({
        %$bet_params,
        duration        => '1m59s',
        landing_company => 'japan',
        barrier         => '101.1'
    });
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/Intraday duration not acceptable/, 'throws error duration not accepted.';
    note('sets duration to 15 minutes.');
    $c = produce_contract({
        %$bet_params,
        duration => '15m',
        barrier  => '101.1'
    });
    ok $c->is_valid_to_buy, 'not valid to buy';
    $c = produce_contract({
        %$bet_params,
        duration => '15m',
        barrier  => 'S11P'
    });
    ok $c->is_valid_to_buy, 'valid to buy';
};

subtest '2-minute touch' => sub {
    $bet_params->{bet_type} = 'ONETOUCH';
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/trying unauthorised combination/, 'throws error duration not accepted.';
    $c = produce_contract({
        %$bet_params,
        landing_company => 'japan',
        barrier         => '101.1'
    });
    ok $c->is_valid_to_buy, 'valid to buy';
    note('sets duration to 1m59s.');
    $c = produce_contract({
        %$bet_params,
        duration        => '1m59s',
        landing_company => 'japan',
        barrier         => '101.1'
    });
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/Intraday duration not acceptable/, 'throws error duration not accepted.';
    $c = produce_contract({
        %$bet_params,
        duration => '1d',
        barrier  => 102
    });
    note('sets duration to 1 day.');
    ok $c->is_valid_to_buy, 'valid to buy';
};

subtest '2-minute upordown' => sub {
    $bet_params->{bet_type}     = 'UPORDOWN';
    $bet_params->{high_barrier} = 'S1000P';
    $bet_params->{low_barrier}  = 'S-1000P';
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/trying unauthorised combination/, 'throws error duration not accepted.';
    $c = produce_contract({
        %$bet_params,
        landing_company => 'japan',
        currency        => 'JPY',
        payout          => 1000
    });
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/barrier should be absolute/, 'throws error barrier type not correct';
    $c = produce_contract({
        %$bet_params,
        landing_company => 'japan',
        high_barrier    => '110',
        low_barrier     => '90',
        currency        => 'JPY',
        payout          => 1000,
    });
    ok $c->is_valid_to_buy, 'valid to buy';
    note('sets duration to 1m59s.');
    $c = produce_contract({
            %$bet_params,
            duration        => '1m59s',
            landing_company => 'japan',
            high_barrier    => '110',
            low_barrier     => '90',

    });
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/Intraday duration not acceptable/, 'throws error duration not accepted.';
};

subtest '2-minute expirymiss' => sub {
    $bet_params->{bet_type}     = 'EXPIRYMISS';
    $bet_params->{high_barrier} = 'S1000P';
    $bet_params->{low_barrier}  = 'S-1000P';
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/trying unauthorised combination/, 'throws error duration not accepted.';
    $c = produce_contract({
        %$bet_params,
        landing_company => 'japan',
        high_barrier    => '110',
        low_barrier     => '90',
        currency        => 'JPY',
        payout          => 1000
    });
    ok $c->is_valid_to_buy, 'valid to buy';
    note('sets duration to 1m59s.');
    $c = produce_contract({
        %$bet_params,
        duration        => '1m59s',
        landing_company => 'japan',
        currency        => 'JPY',
        payout          => 1000,
        high_barrier    => '110',
        low_barrier     => '90',
    });
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/Intraday duration not acceptable/, 'throws error duration not accepted.';
};

done_testing();
