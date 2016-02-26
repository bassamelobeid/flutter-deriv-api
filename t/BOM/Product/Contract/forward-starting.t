#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 6;
use Test::Exception;
use Test::NoWarnings;
use Test::MockTime qw(set_absolute_time);
use Time::HiRes qw(sleep);

use BOM::Product::ContractFactory qw(produce_contract make_similar_contract);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

use Date::Utility;

my $now = Date::Utility->new;
use BOM::Test::Data::Utility::UnitTestMarketData;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol          => $_,
        recorded_date   => $now->minus_time_interval('5m'),
    }) for qw(USD JPY JPY-USD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date   => $now->minus_time_interval('5m'),
    });

subtest 'forward starting with payout/stake' => sub {
    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        duration     => '10m',
        barrier      => 'S0P',
        currency     => 'USD',
        amount_type  => 'payout',
        amount       => 10,
        date_pricing => $now->epoch - 300,
        date_start   => $now
    });
    ok $c->is_forward_starting;
    is $c->payout, 10, 'payout of 10';
};

subtest 'forward starting with stake' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch      => $_,
            underlying => 'frxUSDJPY',
            quote      => 100
        }) for ($now->epoch - 300, $now->epoch + 299);
    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        duration     => '10m',
        barrier      => 'S0P',
        currency     => 'USD',
        amount_type  => 'stake',
        amount       => 10,
        date_pricing => $now->epoch - 300,
        date_start   => $now
    });
    ok $c->is_forward_starting;
    cmp_ok $c->payout, ">", 10, 'payout is > 10';
};

subtest 'forward starting on random nightly' => sub {
    $now = Date::Utility->new->truncate_to_day;
    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'RDBULL',
        duration     => '10m',
        barrier      => 'S0P',
        currency     => 'USD',
        amount_type  => 'payout',
        amount       => 10,
        date_pricing => $now->epoch - 300,
        date_start   => $now
    });
    ok $c->is_forward_starting;
    ok $c->_validate_start_date;
    my @err = $c->_validate_start_date;
    like($err[0]->{message}, qr/in starting blackout/);
    $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'RDBULL',
        duration     => '10m',
        barrier      => 'S0P',
        currency     => 'USD',
        amount_type  => 'payout',
        amount       => 10,
        date_pricing => $now->epoch - 300,
        date_start   => $now->epoch + 301
    });
    ok !$c->_validate_start_date;
};

subtest 'forward starting on random daily' => sub {
    $now = Date::Utility->new->truncate_to_day->plus_time_interval('12h');
    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'RDMARS',
        duration     => '10m',
        barrier      => 'S0P',
        currency     => 'USD',
        amount_type  => 'payout',
        amount       => 10,
        date_pricing => $now->epoch - 300,
        date_start   => $now
    });
    ok $c->is_forward_starting;
    ok $c->_validate_start_date;
    my @err = $c->_validate_start_date;
    like($err[0]->{message}, qr/in starting blackout/);
    $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'RDMARS',
        duration     => '10m',
        barrier      => 'S0P',
        currency     => 'USD',
        amount_type  => 'payout',
        amount       => 10,
        date_pricing => $now->epoch - 300,
        date_start   => $now->epoch + 301
    });
    ok !$c->_validate_start_date;
};

subtest 'end of day blockout period for random nightly and random daily' => sub {
    $now = Date::Utility->new->truncate_to_day->plus_time_interval('23h49m');
    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'RDBULL',
        duration     => '10m',
        barrier      => 'S0P',
        currency     => 'USD',
        amount_type  => 'payout',
        amount       => 10,
        date_pricing => $now->epoch,
        date_start   => $now->epoch,
    });
    ok $c->_validate_expiry_date, 'throw error if contract ends in 1m before expiry';
    my $valid_c = make_similar_contract($c, {duration => '8m59s'});
    ok !$valid_c->_validate_expiry_date;

    $now = Date::Utility->new->truncate_to_day->plus_time_interval('11h49m');
    $c   = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'RDYIN',
        duration     => '10m',
        barrier      => 'S0P',
        currency     => 'USD',
        amount_type  => 'payout',
        amount       => 10,
        date_pricing => $now->epoch,
        date_start   => $now->epoch,
    });
    ok $c->_validate_expiry_date, 'throw error if contract ends in 1m before expiry';
    $valid_c = make_similar_contract($c, {duration => '8m59s'});
    ok !$valid_c->_validate_expiry_date;
};

