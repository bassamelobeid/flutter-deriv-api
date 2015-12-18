#!/usr/bin/perl

use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use Test::More tests => 4;
use Test::NoWarnings;
use Test::Exception;

use BOM::MarketData::Holiday;
use Date::Utility;

my $now = Date::Utility->new;

subtest 'error check' => sub {
    throws_ok {BOM::MarketData::Holiday->new(recorded_date => $now)} qr/required/, 'throws error if not enough argument to create a holiday';
    throws_ok {BOM::MarketData::Holiday->new(calendar => {})} qr/required/, 'throws error if not enough argument to create a holiday';
    lives_ok {BOM::MarketData::Holiday->new(recorded_date => $now, calendar => {})} 'creates a holiday object if all args are present';
};

subtest 'save and retrieve event' => sub {
    lives_ok {
        my $h = BOM::MarketData::Holiday->new(
            recorded_date => $now,
            calendar => {
                $now->epoch => {
                    'Test Event' => ['USD'],
                }
            },
        );
        ok $h->save, 'succesfully saved event.';
        $h = BOM::MarketData::Holiday->new(
            recorded_date => $now,
            calendar => {
                $now->epoch => {
                    'Test Event 2' => ['EURONEXT'],
                }
            },
        );
        ok $h->save, 'sucessfully saved event 2.';
        my $event = BOM::MarketData::Holiday::get_holidays_for('EURONEXT');
        ok $event->{$now->truncate_to_day->epoch}, 'has a holiday';
        is $event->{$now->truncate_to_day->epoch}, 'Test Event 2', 'Found saved holiday';
    } 'saves event';
    my $next_day = $now->plus_time_interval('1d');
    lives_ok {
        my $h = BOM::MarketData::Holiday->new(
            recorded_date => $next_day,
            calendar => {
                $next_day->epoch => {
                    'Test Event Update' => ['AUD'],
                }
            },
        );
        ok $h->save, 'successfully saved event update';
        my $event = BOM::MarketData::Holiday::get_holidays_for('USD');
        ok !$event->{$next_day->truncate_to_day->epoch}, 'no holiday';
        $event = BOM::MarketData::Holiday::get_holidays_for('AUD');
        ok $event->{$next_day->truncate_to_day->epoch}, 'has a holiday';
        is $event->{$next_day->truncate_to_day->epoch}, 'Test Event Update', 'Found saved holiday';
    } 'removed historical holiday when new event is inserted';
};

subtest 'save and retrieve event in history' => sub {
    my $yesterday = $now->minus_time_interval('1d');
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('holiday', {recorded_date => $yesterday, calendar => {$now->epoch => {'Test Historical Save' => ['EURONEXT']}}});
    my $h = BOM::MarketData::Holiday::get_holidays_for('EURONEXT', $yesterday);
    ok $h->{$now->truncate_to_day->epoch}, 'has a holiday';
    is $h->{$now->truncate_to_day->epoch}, 'Test Historical Save', 'Found saved holiday';
    $h = BOM::MarketData::Holiday::get_holidays_for('EURONEXT', $yesterday->minus_time_interval('1d'));
    ok !$h->{$now->truncate_to_day->epoch}, 'no holiday';
};
