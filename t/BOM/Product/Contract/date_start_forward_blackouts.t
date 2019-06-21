#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::FailWarnings;
use Date::Utility;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

my $now = Date::Utility->new('2019-06-20 20:00:00');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(USD JPY-USD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });

my $usdjpy_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch,
    quote      => 100
});
my $r100_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_100',
    epoch      => $now->epoch,
    quote      => 100
});

subtest 'forex forward' => sub {
    my $args = {
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        date_start   => $now->plus_time_interval('15m'),
        date_pricing => $now,
        duration     => '1h1s',
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 100,
    };
    my $c = produce_contract($args);
    ok $c->is_forward_starting, 'forward starting';
    ok !$c->is_valid_to_buy, 'is not valid to buy';
    is_deeply $c->primary_validation_error->message_to_client,
        ['Trading is not available from [_1] to [_2].', '21:00:00', '23:59:59'],
        'error is expected';
    $args->{date_start} = $now->plus_time_interval('1h');
    $c = produce_contract($args);
    ok $c->is_forward_starting, 'forward starting';
    ok !$c->is_valid_to_buy, 'is not valid to buy';
    is_deeply $c->primary_validation_error->message_to_client,
        ['Trading is not available from [_1] to [_2].', '21:00:00', '23:59:59'],
        'error is expected';
};

subtest 'volatility index forward' => sub {
    my $args = {
        bet_type     => 'CALL',
        underlying   => 'R_100',
        date_start   => $now->plus_time_interval('15m'),
        date_pricing => $now,
        duration     => '1h1s',
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 100,
    };
    my $c = produce_contract($args);
    ok $c->is_forward_starting, 'forward starting';
    ok $c->is_valid_to_buy, 'is valid to buy';
    $args->{date_start} = $now->plus_time_interval('1h');
    $c = produce_contract($args);
    ok $c->is_forward_starting, 'forward starting';
    ok $c->is_valid_to_buy, 'is valid to buy';
};

done_testing();
