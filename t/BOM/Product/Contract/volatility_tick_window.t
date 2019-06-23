#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::Exception;
use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

my $now = Date::Utility->new('2019-06-20');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        recorded_date => $now,
        events        => [{
                symbol       => 'USD',
                release_date => $now->minus_time_interval('1s')->epoch,
                source       => 'forexfactory',
                event_name   => 'CB_Leading_Index_m/m',
            },
            {
                symbol       => 'USD',
                release_date => $now->minus_time_interval('1h')->epoch,
                source       => 'forexfactory',
                event_name   => 'CB_Leading_Index_m/m',
            }]});

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

subtest 'economic event crossing end lookup period' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $now->epoch,
        quote      => 100
    });
    my $args = {
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        date_start   => $now,
        date_pricing => $now,
        duration     => '1h',
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 100,
    };
    my $c = produce_contract($args);
    # this is a test to ensure that a bug that causes inverted start and end date request to feed database
    lives_ok { $c->ask_price } 'get ask price without exception';
};

done_testing();
