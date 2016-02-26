#!/usr/bin/perl

use strict;
use warnings;

use Test::More (tests => 3);
use Test::Exception;
use Test::NoWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Runtime qw(:normal);
use BOM::Test::Data::Utility::UnitTestMD qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

initialize_realtime_ticks_db();

use BOM::Market::Underlying;
use BOM::Product::ContractFactory qw( produce_contract );
use Date::Utility;
use BOM::Platform::Runtime;

my $start = Date::Utility->new('12-Mar-13');
my $end   = Date::Utility->new('15-Mar-13');

BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'currency',
    {
        symbol => $_,
        recorded_date   => $start,
    }) for (qw/USD JPY EUR/);

subtest 'discrete points on forex' => sub {
    plan tests => 2;
    my $fx         = BOM::Market::Underlying->new('frxUSDJPY');
    my $bet_params = {
        bet_type     => 'CALL',
        underlying   => $fx,
        date_start   => $start,
        date_expiry  => $end,
        currency     => 'USD',
        payout       => 100,
        barrier      => 'S0P',
        date_pricing => $start,
    };
    my $bet = produce_contract($bet_params);
    is $bet->dividend_adjustment->{spot},    0, 'spot adjustment is zero';
    is $bet->dividend_adjustment->{barrier}, 0, 'barrier adjustment is zero';
};

BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'index',
    {
        symbol => 'DEDAI',
        rates  => {
            2 => 0.1111,
            4 => 0.123,
            3 => 0.234,
            5 => 0.543
        },
        discrete_points => {'2013-03-14' => 2.5},
        recorded_date            => $start
    });

my $cur_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'DEDAI',
    epoch      => $start->epoch + 30,
    quote      => 111
});
BOM::Test::Data::Utility::UnitTestMD::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'DEDAI',
        recorded_date   => $start,
    });
subtest 'discrete dividend on stocks' => sub {
    plan tests => 7;
    my $index      = BOM::Market::Underlying->new('DEDAI');
    my $bet_params = {
        bet_type     => 'CALL',
        underlying   => $index,
        date_start   => $start,
        date_expiry  => $end,
        currency     => 'EUR',
        payout       => 100,
        barrier      => 'S0P',
        date_pricing => $start,
        current_tick => $cur_tick,
    };
    my $bet = produce_contract($bet_params);
    isnt $bet->dividend_adjustment->{spot}, 0, 'spot adjustment is not zero';
    ok $bet->dividend_adjustment->{spot} < 0, 'spot adjustment is negative';
    isnt $bet->dividend_adjustment->{barrier}, 0, 'barrier adjustment is not zero';
    isnt $bet->current_spot, $bet->pricing_args->{spot}, 'spot for pricing is not the current spot';
    is $bet->pricing_spot,   $bet->pricing_args->{spot}, 'spot for pricing is the adjusted spot';
    isnt $bet->barrier->as_absolute, $bet->pricing_args->{barrier1}, 'barrier for pricing is the adjusted barrier';
    is $bet->pricing_args->{q_rate}, 0, 'q_rate is zero if discrete dividend is used';
};
