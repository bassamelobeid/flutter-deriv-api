#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;
use Cache::RedisDB;
BOM::Market::AggTicks->new->flush();

my $now = Date::Utility->new('2016-09-22');
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
    epoch      => $now->epoch,
    quote      => 100
});

my $bet_params = {
    underlying   => 'frxUSDJPY',
    bet_type     => 'CALL',
    date_start   => $now,
    date_pricing => $now,
    duration     => '2m',
    barrier      => '101.1',
    currency     => 'USD',
    payout       => 10,
};
Cache::RedisDB->set('FINDER_PREDEFINED_SET', 'frxUSDJPY==2016-09-22==00', []);
subtest '2-minute non ATM callput' => sub {
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/Intraday duration not acceptable/, 'throws error duration not accepted.';
    $c = produce_contract({%$bet_params, landing_company => 'japan'});
    ok $c->is_valid_to_buy, 'valid to buy';
    note('sets duration to 1m59s.');
    $c = produce_contract({
        %$bet_params,
        duration        => '1m59s',
        landing_company => 'japan'
    });
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/Intraday duration not acceptable/, 'throws error duration not accepted.';
    note('sets duration to 15 minutes.');
    $c = produce_contract({%$bet_params, duration => '15m'});
    ok $c->is_valid_to_buy, 'valid to buy';
};

subtest '2-minute touch' => sub {
    $bet_params->{bet_type} = 'ONETOUCH';
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/trying unauthorised combination/, 'throws error duration not accepted.';
    $c = produce_contract({%$bet_params, landing_company => 'japan'});
    ok $c->is_valid_to_buy, 'valid to buy';
    note('sets duration to 1m59s.');
    $c = produce_contract({
        %$bet_params,
        duration        => '1m59s',
        landing_company => 'japan'
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
    $bet_params->{high_barrier} = 110;
    $bet_params->{low_barrier}  = 90;
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/trying unauthorised combination/, 'throws error duration not accepted.';
    $c = produce_contract({%$bet_params, landing_company => 'japan'});
    ok $c->is_valid_to_buy, 'valid to buy';
    note('sets duration to 1m59s.');
    $c = produce_contract({
        %$bet_params,
        duration        => '1m59s',
        landing_company => 'japan'
    });
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/Intraday duration not acceptable/, 'throws error duration not accepted.';
};

subtest '2-minute expirymiss' => sub {
    $bet_params->{bet_type}     = 'EXPIRYMISS';
    $bet_params->{high_barrier} = 110;
    $bet_params->{low_barrier}  = 90;
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/trying unauthorised combination/, 'throws error duration not accepted.';
    $c = produce_contract({%$bet_params, landing_company => 'japan'});
    ok $c->is_valid_to_buy, 'valid to buy';
    note('sets duration to 1m59s.');
    $c = produce_contract({
        %$bet_params,
        duration        => '1m59s',
        landing_company => 'japan'
    });
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/Intraday duration not acceptable/, 'throws error duration not accepted.';
};

done_testing();
