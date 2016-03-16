#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::NoWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Market::Underlying;
use Date::Utility;

use BOM::Platform::Runtime;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Test::MockModule;

my $now = Date::Utility->new('2016-03-15 01:00:00');
my $delay = $now->minus_time_interval('1m1s');
note('Forex maximum allowed feed delay is 1m');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_, recorded_date => $now}) for qw(USD JPY);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('volsurface_delta', {symbol => 'frxUSDJPY', recorded_date => $now});
my $bet_params = {
    underlying   => 'frxUSDJPY',
    bet_type     => 'CALL',
    currency     => 'USD',
    payout       => 100,
    date_start   => $now,
    date_pricing => $now,
    duration     => '3d',
    barrier      => 'S0P',

};

my $fake_tick = BOM::Market::Data::Tick->new({
    underlying => 'frxUSDJPY',
    epoch => 1,
    quote => 100,
});

my $old_tick;

subtest 'open contracts - missing current tick & quote too old' => sub {
    $bet_params->{basis_tick} = $fake_tick; # basis tick need to be present
    $bet_params->{date_pricing} = $now;
    my $c = produce_contract($bet_params);
    ok !$c->is_expired, 'contract not expired';
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like ($c->primary_validation_error->{message}, qr/No realtime data/, 'no realtime data message');
    $old_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({underlying => 'frxUSDJPY', epoch => $delay->epoch});
    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({underlying => 'frxUSDJPY', epoch => $now->epoch});
    $bet_params->{current_tick} = $old_tick;
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like ($c->primary_validation_error->{message}, qr/Quote too old/, 'no realtime data message');
    $bet_params->{current_tick} = $tick;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
};

subtest 'expired contracts' => sub {
    $bet_params->{date_pricing} = $now->plus_time_interval('4d');
    $bet_params->{current_tick} = $old_tick;
    $bet_params->{exit_tick} = $fake_tick;
    my $c = produce_contract($bet_params);
    ok $c->is_expired, 'contract expired';
    ok !$c->_validate_feed, 'no feed error triggered';
};

