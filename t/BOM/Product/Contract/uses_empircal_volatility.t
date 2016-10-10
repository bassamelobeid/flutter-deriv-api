#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::MockModule;

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db;

my $now        = Date::Utility->new();
my $volsurface = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxXAUUSD',
        recorded_date => $now
    });

subtest 'uses_empirical_vol' => sub {
    my $bet_params = {
        underlying   => 'R_100',
        bet_type     => 'CALL',
        barrier      => 'S0P',
        date_start   => $now,
        date_pricing => $now,
        duration     => '1h',
        currency     => 'USD',
        payout       => 10,
    };
    my $c = produce_contract($bet_params);
    ok !$c->uses_empirical_volatility, 'volatility indices does not use empirical vol';
    $bet_params->{underlying} = 'WLDUSD';
    $c = produce_contract($bet_params);
    is $c->market->name,                        'forex', 'forex market for WLDUSD';
    is $c->underlying->volatility_surface_type, 'flat',  'WLDUSD has flat volatility surface';
    ok !$c->uses_empirical_volatility, 'WLDUSD does not use empirical vol';
    my $overnight_epoch = (sort { $a <=> $b } keys %{$volsurface->variance_table})[1];
    delete $bet_params->{duration};
    $bet_params->{underlying}  = 'frxUSDJPY';
    $bet_params->{date_expiry} = $overnight_epoch;
    $c                         = produce_contract($bet_params);
    is $c->date_expiry->epoch, $overnight_epoch, 'date expiry on overnight tenor';
    ok !$c->uses_empirical_volatility, 'does not use empirical vol';
    $bet_params->{date_expiry} = $overnight_epoch - 1;
    $c = produce_contract($bet_params);
    ok $c->uses_empirical_volatility, 'uses empirical volatility if all conditions are met';
    $bet_params->{underlying} = 'frxXAUUSD';
    $c = produce_contract($bet_params);
    ok $c->uses_empirical_volatility, 'uses empirical volatility if all conditions are met';
    $bet_params->{is_forward_starting} = 1;
    $c = produce_contract($bet_params);
    ok !$c->uses_empirical_volatility, 'not for forward starting contracts though';
};
done_testing();
