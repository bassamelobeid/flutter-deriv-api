#!/usr/bin/perl

use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use Test::More;
use Test::Exception;

use BOM::MarketData::Holiday;
use Date::Utility;

my $now = Date::Utility->new;

subtest 'error check' => sub {
    throws_ok {BOM::MarketData::Holiday->new(date => $now)} qr/required/, 'throws error if not enough argument to create a holiday';
    throws_ok {BOM::MarketData::Holiday->new(date => $now, description => 'test')} qr/required/, 'throws error if not enough argument to create a holiday';
    throws_ok {BOM::MarketData::Holiday->new(affected_symbols => ['USD'], description => 'test')} qr/required/, 'throws error if not enough argument to create a holiday';
    lives_ok {BOM::MarketData::Holiday->new(date => $now, description => 'test', affected_symbols => ['USD'])} 'creates a holiday object if all args are present';
};

subtest 'save and retrieve event' => sub {
    lives_ok {
        my $h = BOM::MarketData::Holiday->new(
            date => $now,
            description => 'Test Event',
            affected_symbols => ['USD'],
        );
        ok $h->save, 'succesfully saved event.';
    } 'saves event';
    lives_ok {
        my $h = BOM::MarketData::Holiday::get_holidays_for('USD');
        ok $h->{$now->truncate_to_day->epoch}, 'has a holiday';
        is $h->{$now->truncate_to_day->epoch}, 'Test Event', 'Found saved holiday';
        $h = BOM::MarketData::Holiday::get_holidays_for('AUD');
        ok !$h->{$now->truncate_to_day->epoch}, 'no holiday';
    }
};

subtest 'save and retrieve event in history' => sub {
    my $yesterday = $now->minus_time_interval('1d');
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('holiday', {date => $now, affected_symbols => ['EURONEXT'], description => 'Test Historical Save', recorded_date => $yesterday});
    my $h = BOM::MarketData::Holiday::get_holidays_for('EURONEXT', $yesterday);
    ok $h->{$now->truncate_to_day->epoch}, 'has a holiday';
    is $h->{$now->truncate_to_day->epoch}, 'Test Historical Save', 'Found saved holiday';
    $h = BOM::MarketData::Holiday::get_holidays_for('EURONEXT', $yesterday->minus_time_interval('1d'));
    ok !$h->{$now->truncate_to_day->epoch}, 'no holiday';
};
