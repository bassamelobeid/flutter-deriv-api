#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;

my $start_epoch = Date::Utility->new->epoch;
$start_epoch -= ($start_epoch % 2);
my $now        = Date::Utility->new($start_epoch);
my $underlying = 'R_100';
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => $underlying,
    epoch      => $now->epoch,
    quote      => 100
});

subtest 'price check for 8-tick and 18s contracts on even second' => sub {
    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => $underlying,
        date_start   => $now,
        date_pricing => $now,
        duration     => '8t',
        barrier      => 'S10P',
        currency     => 'USD',
        payout       => 10,
    });
    my $c1 = produce_contract({
        bet_type     => 'CALL',
        underlying   => $underlying,
        date_start   => $now,
        date_pricing => $now,
        duration     => '18s',
        barrier      => 'S10P',
        currency     => 'USD',
        payout       => 10,
    });
    is $c->ask_price, $c1->ask_price, 'ask price is identical for a 8-tick and 18-second contracts on even second';
};

subtest 'price check for for 8-tick and 16s contract on odd second' => sub {
    my $odd = $now->plus_time_interval('1s');
    my $c   = produce_contract({
        bet_type     => 'CALL',
        underlying   => $underlying,
        date_start   => $odd,
        date_pricing => $odd,
        duration     => '8t',
        barrier      => 'S10P',
        currency     => 'USD',
        payout       => 10,
    });
    my $c1 = produce_contract({
        bet_type     => 'CALL',
        underlying   => $underlying,
        date_start   => $odd,
        date_pricing => $odd,
        duration     => '16s',
        barrier      => 'S10P',
        currency     => 'USD',
        payout       => 10,
    });
    is $c->timeindays->amount,  16 / 86400, 'duration for 8t is 16 seconds';
    is $c1->timeindays->amount, 14 / 86400, 'duration for 16-second contract is 14 seconds';
    ok $c1->ask_price < $c->ask_price,
        'OTM contract, 8-tick contract should be more expensive that 16-second contract if the contract starts at an odd second';
};

done_testing();
