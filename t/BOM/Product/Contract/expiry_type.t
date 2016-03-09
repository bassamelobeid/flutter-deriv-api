#!/usr/bin/perl

use strict;
use warnings;

use BOM::Product::ContractFactory qw(produce_contract);

use Test::More tests => 3;
use Test::Exception;
use Test::NoWarnings;
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestMarketData;
my $time   = time;
my $params = {
    bet_type     => 'CALL',
    underlying   => 'R_100',
    date_start   => $time,
    date_pricing => $time,
    barrier      => 'S0P',
    payout       => 100,
    currency     => 'USD',
};
subtest 'tick expiry' => sub {
    $params->{duration} = '5t';
    lives_ok {
        my $c = produce_contract($params);
        ok $c->tick_expiry, 'is tick expiry';
        is $c->tick_count, 5, '5 ticks contract';
        is $c->date_expiry->epoch, $time + 10, 'has estimated expiry set';
        ok $c->is_intraday, 'tick expiry is labeled as intraday';
        ok !$c->expiry_daily, 'not multiday';
    }
    'tick expiry contract on R_100';
    delete $params->{tick_expiry};
};

subtest 'intraday|multiday' => sub {
    $params->{duration} = '24h';
    lives_ok {
        my $c = produce_contract($params);
        ok !$c->tick_expiry, 'not tick expiry';
        is $c->date_expiry->epoch, $time + 86400, 'correct expiry time';
        ok $c->is_intraday, 'is intraday';
        ok !$c->expiry_daily, ' not expiry daily';
    }
    'intraday contract with 24h duration';
    $params->{duration} = '25h';
    lives_ok {
        my $c = produce_contract($params);
        ok !$c->tick_expiry, 'not tick expiry';
        is $c->date_expiry->epoch, $time + 86400 + 3600, 'correct expiry time';
        ok !$c->is_intraday, 'is intraday';
        ok $c->expiry_daily, ' not expiry daily';
    }
    'not intraday contract with 25h duration';
    $params->{duration} = '1d';
    lives_ok {
        my $c = produce_contract($params);
        ok !$c->tick_expiry, 'not tick expiry';
        is $c->date_expiry->epoch, Date::Utility->new($time)->truncate_to_day->plus_time_interval('1d23h59m59s')->epoch, 'correct expiry time';
        ok !$c->is_intraday, 'is intraday';
        ok $c->expiry_daily, ' not expiry daily';
    }
    'not intraday contract with 2d duration';
};
