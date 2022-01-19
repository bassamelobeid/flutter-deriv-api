use strict;
use warnings;

use Test::More;

use BOM::Product::ContractFactory qw(produce_contract);

my $now = Date::Utility->new('2018-09-18 19:00:00');

my $args = {
    bet_type     => 'CALL',
    underlying   => 'frxUSDJPY',
    date_start   => $now,
    date_pricing => $now,
    duration     => '1h',
    barrier      => 'S0P',
    payout       => 100,
    currency     => 'LTC'
};

subtest 'max payout based on risk profile' => sub {
    #medium risk
    my $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 90, 'medium risk market max payout for LTC is ' . 90);

    #moderate_risk
    $args->{underlying} = 'frxXAUUSD';
    $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 22.5, 'moderate risk market max payout for LTC is ' . 22.5);

    #extreme risk
    $args->{underlying} = 'cryBCHUSD';
    $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 0.45, 'extreme risk market max payout for LTC is ' . 0.45);

    #low risk
    $args->{underlying} = '1HZ100V';
    $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 225, 'low risk market max payout for LTC is ' . 225);
};

subtest 'max payout based on contract category' => sub {
    #contract category : runs
    $args->{bet_type} = 'RUNLOW';
    my $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 45, 'runs contract category max payout for LTC is ' . 45);

    #contract category : digits
    $args->{bet_type} = 'DIGITMATCH';
    $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 135, 'digits contract category max payout for LTC is ' . 135);
};

subtest 'max payout during inefficient period' => sub {

    $now                    = Date::Utility->new('2018-09-18 22:00:00');
    $args->{'date_pricing'} = $now;
    $args->{'date_start'}   = $now;

    $args->{underlying} = 'frxUSDJPY';
    $args->{bet_type}   = 'CALL';

    my $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 0.9, 'max payout during inefficient period for LTC is ' . 0.9);

    $args->{'currency'} = 'BTC';
    $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 0.003, 'max payout during inefficient period for BTC is ' . 0.003);

    $args->{'currency'} = 'ETH';
    $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 0.05, 'max payout during inefficient period for ETH is ' . 0.05);

    $args->{'currency'} = 'IDK';
    $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 2780, 'max payout during inefficient period for IDK is ' . 2780);

    $args->{'currency'} = 'USD';
    $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 200, 'max payout during inefficient period for USD is ' . 200);
};

done_testing;
