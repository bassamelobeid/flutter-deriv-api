#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract make_similar_contract);

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

initialize_realtime_ticks_db();

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        recorded_date => Date::Utility->new,
        symbol        => 'USD',
    });

my $contract = produce_contract({
    bet_type => 'CALL',
    underlying => 'R_100',
    barrier => 'S0P',
    currency => 'USD',
    amount_type => 'stake',
    amount => 100,
});

ok $contract->build_parameters->{ask_price}, 'ask_price defined';
is $contract->ask_price, 100, 'ask_price is 100';

my $similar = make_similar_contract($contract, {amount_type => 'payout', amount => 10});
ok !$similar->build_parameters->{ask_price}, 'ask_price not defined';
isnt $similar->ask_price, 100, 'ask price is recalculated';

done_testing;
