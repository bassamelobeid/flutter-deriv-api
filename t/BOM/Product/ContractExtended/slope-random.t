#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 13;
use Test::NoWarnings;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use Date::Utility;

my $now = Date::Utility->new()->truncate_to_day->plus_time_interval('1h');
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('index', {symbol => $_}) for qw(RDMARS RDSUN RDMOON RDVENUS);
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency', {symbol => 'USD'});

foreach my $u (qw(RDMOON RDSUN RDMARS RDVENUS)) {
    my $expected_vols = {
        RDSUN   => [1.8828823593468,   1.94226844750148],
        RDVENUS => [0.579481102216808, 0.603998783804617],
        RDMOON  => [1.1205788609051,   1.05856924258951],
        RDMARS  => [2.42141666995312,  2.39629086415781],
    };

    my $pp = {
        bet_type     => 'EXPIRYMISS',
        underlying   => $u,
        high_barrier => 'S400000P',
        low_barrier  => 'S-400000P',
        date_start   => $now,
        date_pricing => $now,
        duration     => '1h',
        currency     => 'USD',
        payout       => 100,
    };
    my $expected = $expected_vols->{$u};
    my $contract = produce_contract($pp);
    is $contract->_market_data->{get_volatility}->(), $expected->[0], "$u start time = pricing time ";
    $pp->{date_pricing} = $now->plus_time_interval('30m');
    $contract = produce_contract($pp);
    is $contract->_market_data->{get_volatility}->(), $expected->[1], "$u pricing time is 30 minutes after start time";
}

foreach my $u (qw(RDMARS RDVENUS)) {
    my $now           = Date::Utility->new->truncate_to_day->plus_time_interval('23h');
    my $expected_vols = {
        RDMARS  => [2.46643360112872,  2.46369198782349],
        RDVENUS => [0.535111322065485, 0.538088961392563],
    };
    my $pp = {
        bet_type     => 'EXPIRYMISS',
        underlying   => $u,
        high_barrier => 'S400000P',
        low_barrier  => 'S-400000P',
        date_start   => $now,
        date_pricing => $now,
        duration     => '3h',
        currency     => 'USD',
        payout       => 100,
    };
    my $expected = $expected_vols->{$u};
    my $contract = produce_contract($pp);
    is $contract->_market_data->{get_volatility}->(), $expected->[0], "$u start time = pricing time ";
    $pp->{date_pricing} = $now->plus_time_interval('30m');
    $contract = produce_contract($pp);
    is $contract->_market_data->{get_volatility}->(), $expected->[1], "$u pricing time is 30 minutes after start time";
}
