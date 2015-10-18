#!/usr/bin/perl

use strict;
use warnings;
use Test::More tests => 10;
use Test::Exception;
use Test::NoWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;
use Format::Util::Numbers qw(roundnear);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

## skip now. FIXME
if (($ENV{TEST_SUITE} || '') eq 'cover') {
    plan skip_all => "It fails under cover right now. skipping.";
}

initialize_realtime_ticks_db();

my $now = Date::Utility->new('2014-11-11');

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol => 'FOREX',
        date   => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => $_,
        date   => $now,
    }) for (qw/JPY USD JPY-USD/);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now,
        surface       => {
            7 => {
                smile => {
                    25 => 0.099,
                    50 => 0.1,
                    75 => 0.11
                },
                vol_spread => {50 => 0.01}
            },
            14 => {
                smile => {
                    25 => 0.099,
                    50 => 0.1,
                    75 => 0.11
                },
                vol_spread => {50 => 0.01}
            },
        },
    });

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch - 3600,
    quote      => 100
});

# forward starting
my $params = {
    bet_type     => 'INTRADU',
    underlying   => 'frxUSDJPY',
    date_start   => $now,
    date_pricing => $now->epoch - 3600,
    duration     => '15m',
    currency     => 'USD',
    barrier      => 'S0P',
    payout       => 100,
};

lives_ok {
    my $c  = produce_contract($params);
    my $pe = $c->pricing_engine;
    is $pe->bs_probability, 0.500945676374959, 'correct bs probability';
    is $pe->probability,    0.5009578548037,   'correct theo probability';
    ok !exists $pe->debug_information->{CALL}{theo_probability}{parameters}{numeraire_probability}{parameters}{slope_adjustment},
        'did not apply slope adjustment for forward starting';
}
'forward starting slope';

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency_config',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for qw( JPY USD );

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch,
    quote      => 100
});

delete $params->{date_pricing};
lives_ok {
    my $c = produce_contract({
        %$params,
        underlying   => 'frxUSDJPY',
        date_pricing => $now,
        bet_type     => 'CALL',
        duration     => '10d',
    });
    my $pe = $c->pricing_engine;
    is $pe->bs_probability, 0.503170070758588, 'correct bs probability';
    is $pe->probability,    0.536635601062016, 'correct theo probability';
    ok exists $pe->debug_information->{CALL}{theo_probability}{parameters}{numeraire_probability}{parameters}{slope_adjustment},
        'did not apply slope adjustment for forward starting';
    is roundnear(0.0001, $pe->debug_information->{CALL}{theo_probability}{parameters}{numeraire_probability}{parameters}{slope_adjustment}{amount}),
        0.0333, 'correct slope adjustment';
}
'now starting slope';
