#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::Exception;
use Test::MockModule;

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(USD JPY-USD);
my @ticks = map { BOM::Test::Data::Utility::FeedTestDatabase::create_tick({underlying => 'frxUSDJPY', quote => 100, epoch => $_,}) }
    ($now->epoch, $now->plus_time_interval('1m')->epoch, $now->plus_time_interval('1m59s')->epoch, $now->plus_time_interval('3m')->epoch);

subtest 'inverted date' => sub {
    my $mocked = Test::MockModule->new('BOM::Product::Contract::Call');
    $mocked->mock('is_expired', sub { return 0 });
    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        date_start   => $now,
        date_expiry  => $now->plus_time_interval('2m'),
        date_pricing => $now->plus_time_interval('2m1s'),
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 1,
        current_tick => $ticks[0],
    });
    lives_ok { $c->bid_price } 'bid price called without throwing an exception';
    ok !$c->is_expired, 'not expired';
};

done_testing();
