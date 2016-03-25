#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::NoWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Date::Utility;

my $now = Date::Utility->new();

initialize_realtime_ticks_db;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency',{symbol => 'USD', recorded_date => $now});

subtest 'sellback conditions' => sub {
    my $date_pricing = $now->plus_time_interval('59s');
    my $entry_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch => $now->epoch,
    });
    my $current_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch => $date_pricing->epoch,
    });
    my $params = {
        bet_type => 'CALL',
        underlying => 'R_100',
        barrier => 'S0P',
        duration => '1h',
        currency => 'USD',
        payout => 10,
        entry_tick => $entry_tick,
        current_tick => $current_tick,
        date_start => $now,
        date_pricing => $date_pricing,
        built_with_bom_parameters => 1,
    };
    my $c = produce_contract($params);
    ok !$c->is_valid_to_sell, 'not valid to sell';
    like (($c->primary_validation_error)[0]->{message}, qr/Contract not held long enough/, 'correct error message');
    $params->{date_pricing} = $now->plus_time_interval('1m');
    $c = produce_contract($params);
    ok $c->is_valid_to_sell, 'valid to sell';
};
