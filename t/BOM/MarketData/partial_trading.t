#!/usr/bin/perl

use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use Test::More tests => 4;
use Test::NoWarnings;
use Test::Exception;

use BOM::MarketData::PartialTrading;
use Date::Utility;

my $now = Date::Utility->new;

subtest 'error check' => sub {
    throws_ok { BOM::MarketData::PartialTrading->new(recorded_date => $now) } qr/required/, 'throws error if not enough argument to create a early close calendar';
    throws_ok { BOM::MarketData::PartialTrading->new(calendar => {}) } qr/required/, 'throws error if not enough argument to create a early close calendar';
    lives_ok { BOM::MarketData::PartialTrading->new(type => 'early_closes', recorded_date => $now, calendar => {}) } 'creates a early close object if all args are present';
};

subtest 'save and retrieve early close dates' => sub {
    lives_ok {
        my $ec = BOM::MarketData::PartialTrading->new(
            type => 'early_closes',
            recorded_date => $now,
            calendar => {
                $now->epoch => {
                    "18:00" => ['FOREX'],
                },
            },
        );
        ok $ec->save, 'successfully save early close calendar';
        $ec = BOM::MarketData::PartialTrading->new(
            type => 'early_closes',
            recorded_date => $now,
            calendar => {
                $now->epoch => {
                    "18:00" => ['ASX'],
                },
                $now->plus_time_interval('2d')->epoch => {
                    "21:00" => ['ASX'],
                },
            },
        );
        ok $ec->save, 'save second early close calendar';
    } 'save early close calendar';
    lives_ok {
        my $early_closes = BOM::MarketData::PartialTrading::get_partial_trading_for('early_closes', 'FOREX');
        is scalar(keys %$early_closes), 1, 'retrieved one early close date for FOREX';
        is $early_closes->{$now->truncate_to_day->epoch}, "18:00", 'correct early close time';
        $early_closes = BOM::MarketData::PartialTrading::get_partial_trading_for('early_closes', 'ASX');
        is scalar(keys %$early_closes), 2, 'retrieved one early close date for ASX';
        is $early_closes->{$now->truncate_to_day->epoch}, "18:00", 'correct early close time';
        is $early_closes->{$now->plus_time_interval('2d')->truncate_to_day->epoch}, "21:00", 'correct early close time';
    } 'retrieve early close calendar';
};

subtest 'save and retrieve early closes in history' => sub {
    my $yesterday = $now->minus_time_interval('1d');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'partial_trading',
        {
            type => 'early_closes',
            recorded_date => $yesterday,
            calendar      => {$now->epoch => {'18:00' => ['EURONEXT']}}});
    my $h = BOM::MarketData::PartialTrading::get_partial_trading_for('early_closes', 'EURONEXT', $yesterday);
    ok $h->{$now->truncate_to_day->epoch}, '18:00';
    $h = BOM::MarketData::PartialTrading::get_partial_trading_for('early_closes', 'EURONEXT', $yesterday->minus_time_interval('1d'));
    ok !$h->{$now->truncate_to_day->epoch}, 'no early close dates';
};
