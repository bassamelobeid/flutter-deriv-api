#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_10',
    epoch      => $now->epoch,
    quote      => 100
});

subtest 'staking limits turbos' => sub {
    my $args = {
        bet_type     => 'TURBOSSHORT',
        underlying   => 'R_10',
        date_start   => $now,
        date_pricing => $now,
        duration     => '10h',
        currency     => 'USD',
        amount_type  => 'stake',
        amount       => 0.0,
        barrier      => '+195.55',
    };

    my $c = produce_contract($args);
    my $err;
    ok $err = $c->_validate_price_non_binary, 'error is thrown';
    is $err->{message}, 'Stake can not be zero .', 'correct error message thrown if stake ask price equals to 0 for Turbos';

    $args->{amount} = 0.35;
    $c = produce_contract($args);
    ok !$c->_validate_price_non_binary, 'no error';

    $args->{amount} = 0.054;
    $c = produce_contract($args);
    ok $err = $c->_validate_price_non_binary, 'error is thrown';
    is $err->{message}, 'Stake amount has too many decimal places.',
        'correct error message thrown if stake amount has more than expected decimal places.';

    $args->{amount} = 0.54;
    $c = produce_contract($args);
    ok !$c->_validate_price_non_binary, 'no error';

    $args->{amount} = 0.000005;
    $c = produce_contract($args);
    ok $err = $c->_validate_price_non_binary, 'error is thrown';
    is $err->{message}, 'Stake amount has too many decimal places.',
        'correct error message thrown if stake amount has more than expected decimal places.';

};

subtest 'staking limits' => sub {
    my $args = {
        bet_type     => 'DIGITMATCH',
        date_start   => $now,
        date_pricing => $now,
        underlying   => 'R_10',
        duration     => '5t',
        currency     => 'USD',
        payout       => 30001,
        barrier      => 0
    };
    my $c = produce_contract($args);
    my $err;
    ok $err = $c->_validate_price, 'error is thrown';
    is $err->{message}, 'payout amount outside acceptable range [given: 0.35] [max: 30000.00]',
        'correct error message thrown if payout exceeded max for DIGITMATCH';
    $args->{payout} = 30000;
    $c = produce_contract($args);
    ok !$c->_validate_price, 'no error';
    $args->{bet_type} = 'RUNHIGH';
    $args->{payout}   = 10001;
    $args->{barrier}  = 'S0P';
    $c                = produce_contract($args);
    ok $err = $c->_validate_price, 'error is thrown';
    is $err->{message}, 'payout amount outside acceptable range [given: 0.35] [max: 10000.00]',
        'correct error message thrown if payout exceeded max RUNHIGH';
    $args->{payout} = 10000;
    $c = produce_contract($args);
    ok !$c->_validate_price, 'no error';
    $args->{bet_type} = 'CALL';
    $args->{barrier}  = 'S0P';
    $args->{payout}   = 50000;
    $c                = produce_contract($args);
    ok !$c->_validate_price, 'no error';
};

subtest 'staking limits vanilla' => sub {
    my $args = {
        bet_type     => 'Vanillalongput',
        underlying   => 'R_10',
        date_start   => $now,
        date_pricing => $now,
        duration     => '10h',
        currency     => 'USD',
        amount_type  => 'stake',
        amount       => 0.0,
        barrier      => '+17.20',
    };

    my $c = produce_contract($args);
    my $err;
    ok $err = $c->_validate_price_non_binary, 'error is thrown';
    is $err->{message}, 'Stake can not be zero .', 'correct error message thrown if stake ask price equals to 0 for Vanilla';

    $args->{amount} = 0.4;
    $c = produce_contract($args);
    ok !$c->_validate_price_non_binary, 'no error';

    $args->{amount} = 0.054;
    $c = produce_contract($args);
    ok $err = $c->_validate_price_non_binary, 'error is thrown';
    is $err->{message}, 'Stake amount has too many decimal places.',
        'correct error message thrown if stake amount has more than expected decimal places.';

    $args->{amount} = 0.54;
    $c = produce_contract($args);
    ok !$c->_validate_price_non_binary, 'no error';

    $args->{amount} = 0.000007;
    $c = produce_contract($args);
    ok $err = $c->_validate_price_non_binary, 'error is thrown';
    is $err->{message}, 'Stake amount has too many decimal places.',
        'correct error message thrown if stake amount has more than expected decimal places.';

};

done_testing;

