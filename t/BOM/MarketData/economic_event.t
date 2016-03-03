#!/usr/bin/perl

use Test::More (tests => 3);
use Test::NoWarnings;
use Test::Exception;

use BOM::Test::Runtime qw(:normal);
use BOM::MarketData::Fetcher::EconomicEvent;
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use BOM::MarketData::EconomicEventCalendar;
use BOM::Platform::Runtime;
use Date::Utility;

my $now = Date::Utility->new;
subtest sanity_check => sub {
    my $new_eco = BOM::MarketData::EconomicEventCalendar->new({
        events        => [ { 
                symbol        => 'USD',
                release_date  => Date::Utility->new(time + 20000)->epoch,
                source        => 'forexfactory',
            }],
        recorded_date => Date::Utility->new,
    });
    isa_ok($new_eco->recorded_date, 'Date::Utility');
    my $eco;
    my $dt = Date::Utility->new();
    lives_ok {

        $eco = BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'economic_events', {
            events => [ {
                        symbol       => 'USD',
                        release_date => $dt->epoch,
                        source       => 'forexfactory',
                        impact       => 3,
                        event_name   => 'FOMC',
                    }]},
        );
    } 'lives if recorded_date is not specified';

    my $eco_event = $eco->events->[0];

    is($eco_event->{impact},     3,           'impact is loaded correctly');
    is($eco_event->{source}, 'forexfactory', 'source is correct');
    is($eco_event->{event_name}, 'FOMC', 'event_name loaded correctly');
    is($eco_event->{release_date}, $dt->epoch, 'release_date loaded correctly');
    is($eco_event->{symbol}, 'USD', 'symbol loaded correctly');
};

subtest save_event_to_chronicle => sub {
    my $today        = Date::Utility->new;
    my $release_date = Date::Utility->new($today->epoch + 3600);

    my $calendar;
   
    lives_ok {
        $calendar = BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
            'economic_events', {
                recorded_date => $today,
                events => [ {
                        symbol        => 'USD',
                        release_date  => $release_date->epoch,
                        source        => 'forexfactory',
                        event_name    => 'my_test_name',
                    }]},
        ); } 'save didn\'t die';

    my $dm   = BOM::MarketData::Fetcher::EconomicEvent->new;
    my @docs = $dm->get_latest_events_for_period({
            from         => $release_date,
            to           => $release_date
        });
    ok scalar @docs > 0, 'document saved';
};

1;
