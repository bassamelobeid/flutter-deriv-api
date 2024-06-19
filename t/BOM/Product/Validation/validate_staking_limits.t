use strict;
use warnings;

use Test::More;
use Test::MockModule;
use BOM::Product::ContractFactory qw(produce_contract);

my $now = Date::Utility->new('2018-09-18 19:00:00');

my $mocked_redis = Test::MockModule->new("RedisDB");

my %dataset = (
    'exchange_rates::LTC_USD' => {
        source           => 'Feed',
        offer_to_clients => 1,
        shift_in_rate    => 0,
        quote            => 55.56800,
        epoch            => time,
    },
    'exchange_rates::BTC_USD' => {
        source           => 'Feed',
        offer_to_clients => 1,
        shift_in_rate    => '-0.0379805941505417',
        quote            => 22371.350,
        epoch            => time,
    },
    'exchange_rates::ETH_USD' => {
        source           => 'Feed',
        offer_to_clients => 1,
        shift_in_rate    => 0,
        quote            => 1587.02050,
        epoch            => time,
    },
);

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
    $mocked_redis->mock('hgetall', sub { my ($self, $key) = @_; return [%{$dataset{$key} // {}}] });

    #medium risk
    my $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 400, 'medium risk market max payout for LTC is ' . 400);

    #moderate_risk
    $args->{underlying} = 'frxXAUUSD';
    $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 100, 'moderate risk market max payout for LTC is ' . 100);

    #extreme risk
    $args->{underlying} = 'cryBCHUSD';
    $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 2, 'extreme risk market max payout for LTC is ' . 2);

    #low risk
    $args->{underlying} = '1HZ100V';
    $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 1000, 'low risk market max payout for LTC is ' . 1000);
};

subtest 'max payout based on contract category' => sub {
    $mocked_redis->mock('hgetall', sub { my ($self, $key) = @_; return [%{$dataset{$key} // {}}] });

    #contract category : runs
    $args->{bet_type} = 'RUNLOW';
    my $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 200, 'runs contract category max payout for LTC is ' . 200);

    #contract category : digits
    $args->{bet_type} = 'DIGITMATCH';
    $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 500, 'digits contract category max payout for LTC is ' . 500);
};

subtest 'max payout during inefficient period' => sub {
    $mocked_redis->mock('hgetall', sub { my ($self, $key) = @_; return [%{$dataset{$key} // {}}] });

    $now                    = Date::Utility->new('2018-09-18 22:00:00');
    $args->{'date_pricing'} = $now;
    $args->{'date_start'}   = $now;

    $args->{underlying} = 'frxUSDJPY';
    $args->{bet_type}   = 'CALL';

    my $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 4, 'max payout during inefficient period for LTC is ' . 4);

    $args->{'currency'} = 'BTC';
    $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 0.01, 'max payout during inefficient period for BTC is ' . 0.01);

    $args->{'currency'} = 'ETH';
    $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 0.13, 'max payout during inefficient period for ETH is ' . 0.13);

    $args->{'currency'} = 'USD';
    $c = produce_contract($args);
    is($c->staking_limits->{'max'}, 200, 'max payout during inefficient period for USD is ' . 200);
};

done_testing;
