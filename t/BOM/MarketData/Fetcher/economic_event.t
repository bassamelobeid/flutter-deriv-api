#!/usr/bin/perl

use strict;
use warnings;

use Test::Most (tests => 5);
use Test::NoWarnings;
use Test::Exception;

use BOM::Test::Runtime qw(:normal);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::MarketData::Fetcher::EconomicEvent;
use String::Random;

subtest create_doc => sub {
    plan tests => 4;
    my $eco = BOM::MarketData::Fetcher::EconomicEvent->new();
    can_ok($eco, 'create_doc');
    my %test_data = (
        recorded_date => '12-12-12',
        release_date  => Date::Utility->new('12-Dec-12 01:00')->epoch
    );
    my $doc_id;
    ok($doc_id = $eco->create_doc(\%test_data), 'create_doc lives');
    my $saved_doc;
    is($saved_doc->{release_date}, $test_data{release_date}, 'data saved successful');
};

subtest retrieve_doc_with_view => sub {
    plan tests => 3;
    my $eco        = BOM::MarketData::Fetcher::EconomicEvent->new();
    my $test_data1 = {
        recorded_date => '2012-09-12T02:10:00Z',
        release_date  => Date::Utility->new('12-Dec-12 03:00')->epoch,
        symbol        => 'USD',
        source        => 'forexfactory',
    };
    my $test_data2 = {
        recorded_date => '2012-09-12T05:10:00Z',
        release_date  => Date::Utility->new('12-Dec-12 03:00')->epoch,
        symbol        => 'USD',
        source        => 'forexfactory',
    };
    my $test_data3 = {
        recorded_date => '2012-09-13T02:10:00Z',
        release_date  => Date::Utility->new('12-Dec-12 03:00')->epoch,
        symbol        => 'EUR',
        source        => 'forexfactory',
    };
    lives_ok { $eco->create_doc($test_data1) } 'test data1 lives';
    lives_ok { $eco->create_doc($test_data2) } 'test data2 lives';
    lives_ok { $eco->create_doc($test_data3) } 'test data3 lives';
};

subtest get_latest_events_for_period => sub {
    plan tests => 7;
    my $today = Date::Utility->new->truncate_to_day;

    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'economic_events',
        {
            recorded_date => $today,
            release_date  => Date::Utility->new($today->epoch + 3600),
            date          => Date::Utility->new(),
        },
    );

    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'economic_events',
        {
            recorded_date => $today,
            release_date  => Date::Utility->new($today->epoch + 2600),
            date          => Date::Utility->new(),
        },
    );

    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'economic_events',
        {
            recorded_date => $today,
            release_date  => Date::Utility->new($today->epoch + 4600),
            date          => Date::Utility->new(),
        },
    );

    my $eco = BOM::MarketData::Fetcher::EconomicEvent->new();
    my $event;
    lives_ok {
        $event = $eco->get_latest_events_for_period({
            from => Date::Utility->new($today->epoch + 1600),
            to   => Date::Utility->new($today->epoch + 6600),
        });
    }
    'get_latest_events_for_period lives';
    is(scalar @$event, 3, 'retrieved the right number of events');
    my $latest = $event->[0];
    is($latest->impact,              1,                     'got the correct impact');
    is($latest->event_name,          'US GDP Announcement', 'got the correct event_name');
    is($latest->release_date->epoch, $today->epoch + 2600,  'got the corect release_date');

    lives_ok {
        $event = $eco->get_latest_events_for_period({
            to   => Date::Utility->new($today->epoch + 1600),
            from => Date::Utility->new($today->epoch + 6600),
        });
    }
    'get_latest_events_for_period lives even with backward periods.';
    is(scalar @$event, 0, '...but gives you 0 events.');

};

subtest multiday_requests => sub {
    plan tests => 10;
    # Other tests can't/don't clean up after themselves, so lets go back to the future!
    my $future_today     = Date::Utility->today->plus_time_interval('365d');
    my $future_yesterday = $future_today->minus_time_interval('1d');
    my $future_tomorrow  = $future_today->plus_time_interval('1d');
    my $future_next_week = $future_today->plus_time_interval('7d');
    my $future_next_year = $future_today->plus_time_interval('365d');

    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'economic_events',
        {
            recorded_date => $future_yesterday,
            release_date  => $future_today->minus_time_interval('1s'),
            date          => Date::Utility->new(),
        },
    );
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'economic_events',
        {
            recorded_date => $future_yesterday,
            release_date  => $future_today,
            date          => Date::Utility->new(),
        },
    );
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'economic_events',
        {
            recorded_date => $future_today,
            release_date  => $future_today->plus_time_interval('3h'),
            date          => Date::Utility->new(),
        },
    );
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'economic_events',
        {
            recorded_date => $future_today,
            release_date  => $future_tomorrow,
            date          => Date::Utility->new(),
        },
    );
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'economic_events',
        {
            recorded_date => $future_today,
            release_date  => $future_next_week,
            date          => Date::Utility->new(),
        },
    );
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'economic_events',
        {
            recorded_date => $future_today,
            release_date  => $future_next_week->plus_time_interval('1s'),
            date          => Date::Utility->new(),
        },
    );

    my $eco         = BOM::MarketData::Fetcher::EconomicEvent->new();
    my $full_events = $eco->get_latest_events_for_period({
        from => $future_yesterday,
        to   => $future_next_year,
    });
    is(scalar @$full_events, 6, 'Year long request finds all seven events properly entered');
    eq_or_diff($full_events, [sort { $a->release_date->epoch <=> $b->release_date->epoch } (@$full_events)], '... all in the right order.');

    my $not_after_midnight_next_week = $eco->get_latest_events_for_period({
        from => $future_yesterday,
        to   => $future_next_week,
    });
    is(scalar @$not_after_midnight_next_week, 5, '... moving the end to just next week drops one event.');

    my $next_week = $eco->get_latest_events_for_period({
        from => $future_yesterday,
        to   => $future_next_week->minus_time_interval('1s'),
    });
    is(scalar @$next_week, 4, '....moving the end back before midnight drops another.');

    $next_week = $eco->get_latest_events_for_period({
        from => $future_today,
        to   => $future_next_week->minus_time_interval('1s'),
    });
    is(scalar @$next_week, 3, '....moving the start up a day drops one more.');

    $next_week = $eco->get_latest_events_for_period({
        from => $future_today->plus_time_interval('1s'),
        to   => $future_next_week->minus_time_interval('1s'),
    });
    is(scalar @$next_week, 2, '....moving the start up aanother second drops one more.');

    my $future_yesterday_events = $eco->get_latest_events_for_period({
        from => $future_yesterday,
        to   => $future_today->minus_time_interval('1s'),
    });
    is(scalar @$future_yesterday_events, 1, 'One event for yesterday to just before midnight today.');

    $future_yesterday_events = $eco->get_latest_events_for_period({
        from => $future_yesterday,
        to   => $future_today,
    });
    is(scalar @$future_yesterday_events, 2, 'Two events for yesterday to midnight today.');

    my $contract_events = $eco->get_latest_events_for_period({
        from => $future_today->minus_time_interval('1h'),
        to   => $future_today->plus_time_interval('5h'),
    });
    is(scalar @$contract_events, 3, 'Three events for a faux contract period starting at 0200 for 2 hours.');

    $contract_events = $eco->get_latest_events_for_period({
        from => $future_today,
        to   => $future_today->plus_time_interval('8h'),
    });
    is(scalar @$contract_events, 2, 'And two events for a faux contract period starting at 0400 for 4 hours.');

};

1;
