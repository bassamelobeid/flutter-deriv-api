#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 9;
use Test::NoWarnings;

use BOM::Product::ContractFactory qw(produce_contract);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();
my $now = Date::Utility->new('2014-11-11');

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol => 'RANDOM',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => 'USD',
        date   => $now,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'index',
    {
        symbol => 'R_50',
        date   => $now,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'R_50',
        recorded_date => $now,
    });

my $params = {
    currency    => 'USD',
    payout      => 100,
    date_start  => time,
    underlying  => 'R_50',
    tick_expiry => 1,
    tick_count  => 10
};
my $c = produce_contract({
    %$params,
    bet_type => 'DIGITMATCH',
});
is $c->code, 'DIGITMATCH', 'correct bet type';
is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Digits', 'correct engine';
is $c->bs_probability->amount, 0.1, 'bs probability is 0.1';
is $c->total_markup->amount, 0.0015228426395939, 'total markup is 0.0015228426395939';

$c = produce_contract({
    %$params,
    bet_type => 'DIGITDIFF',
});
is $c->code, 'DIGITDIFF', 'correct bet type';
is $c->pricing_engine_name, 'BOM::Product::Pricing::Engine::Digits', 'correct engine';
is $c->bs_probability->amount, 0.9, 'bs probability is 0.9';
is $c->total_markup->amount, 0.00909090909090909, 'total markup 0.00909090909090909';
1;
