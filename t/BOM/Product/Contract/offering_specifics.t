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

my $now = Date::Utility->new;
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
    barrier      => '100.1',
    currency     => 'USD',
    payout       => 10
};

subtest '2-minute non ATM callput' => sub {
    my $c = produce_contract($bet_params);
    is $c->landing_company, 'costarica', 'default landing company, costarica.';
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/Intraday duration not acceptable/, 'throws error duration not accepted.';
    $c = produce_contract({%$bet_params, landing_company => 'japan'});
    is $c->landing_company, 'japan', 'landing company set to japan';
    ok $c->is_valid_to_buy, 'valid to buy';
    note('sets duration to 1m59s.');
    $c = produce_contract({
        %$bet_params,
        duration        => '1m59s',
        landing_company => 'japan'
    });
    is $c->landing_company, 'japan', 'landing company set to japan';
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/Intraday duration not acceptable/, 'throws error duration not accepted.';
    note('sets duration to 15 minutes.');
    $c = produce_contract({%$bet_params, duration => '15m'});
    is $c->landing_company, 'costarica', 'default landing company, costarica.';
    ok $c->is_valid_to_buy, 'valid to buy';
};

subtest '2-minute touch' => sub {
    $bet_params->{bet_type} = 'ONETOUCH';
    my $c = produce_contract($bet_params);
    is $c->landing_company, 'costarica', 'default landing company, costarica.';
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/trying unauthorised combination/, 'throws error duration not accepted.';
    $c = produce_contract({%$bet_params, landing_company => 'japan'});
    is $c->landing_company, 'japan', 'landing company set to japan';
    ok $c->is_valid_to_buy, 'valid to buy';
    note('sets duration to 1m59s.');
    $c = produce_contract({
        %$bet_params,
        duration        => '1m59s',
        landing_company => 'japan'
    });
    is $c->landing_company, 'japan', 'landing company set to japan';
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/Intraday duration not acceptable/, 'throws error duration not accepted.';
    $c = produce_contract({
        %$bet_params,
        duration => '1d',
        barrier  => 102
    });
    note('sets duration to 1 day.');
    is $c->landing_company, 'costarica', 'default landing company, costarica.';
    ok $c->is_valid_to_buy, 'valid to buy';
};

subtest '2-minute upordown' => sub {
    $bet_params->{bet_type}     = 'UPORDOWN';
    $bet_params->{high_barrier} = 110;
    $bet_params->{low_barrier}  = 90;
    my $c = produce_contract($bet_params);
    is $c->landing_company, 'costarica', 'default landing company, costarica.';
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/trying unauthorised combination/, 'throws error duration not accepted.';
    $c = produce_contract({%$bet_params, landing_company => 'japan'});
    is $c->landing_company, 'japan', 'landing company set to japan';
    ok $c->is_valid_to_buy, 'valid to buy';
    note('sets duration to 1m59s.');
    $c = produce_contract({
        %$bet_params,
        duration        => '1m59s',
        landing_company => 'japan'
    });
    is $c->landing_company, 'japan', 'landing company set to japan';
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/Intraday duration not acceptable/, 'throws error duration not accepted.';
};

subtest '2-minute expirymiss' => sub {
    $bet_params->{bet_type}     = 'EXPIRYMISS';
    $bet_params->{high_barrier} = 110;
    $bet_params->{low_barrier}  = 90;
    my $c = produce_contract($bet_params);
    is $c->landing_company, 'costarica', 'default landing company, costarica.';
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/trying unauthorised combination/, 'throws error duration not accepted.';
    $c = produce_contract({%$bet_params, landing_company => 'japan'});
    is $c->landing_company, 'japan', 'landing company set to japan';
    ok $c->is_valid_to_buy, 'valid to buy';
    note('sets duration to 1m59s.');
    $c = produce_contract({
        %$bet_params,
        duration        => '1m59s',
        landing_company => 'japan'
    });
    is $c->landing_company, 'japan', 'landing company set to japan';
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like $c->primary_validation_error->message, qr/Intraday duration not acceptable/, 'throws error duration not accepted.';
};

done_testing();
