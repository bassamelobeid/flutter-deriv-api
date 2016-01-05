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

BOM::Platform::Runtime->instance->app_config->quants->market_data->economic_announcements_source('forexfactory');
my $now = Date::Utility->new;
subtest sanity_check => sub {
    my $new_eco = BOM::MarketData::EconomicEventCalendar->new({
        events        => [ { 
                symbol        => 'USD',
                release_date  => Date::Utility->new(time + 20000),
                source        => 'forexfactory',
            }],
        recorded_date => Date::Utility->new,
    });
    isa_ok($new_eco->recorded_date, 'Date::Utility');
    my $eco;
    lives_ok {
        $eco = BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'economic_events', {
            events => [ {
                        symbol       => 'USD',
                        release_date => time + 5000,
                        source       => 'forexfactory',
                    }]},
        );
    } 'lives if recorded_date is not specified';

    my $eco_event = $eco->events->[0];
    is($eco_event->impact,     5,           'default to the highest impact value [5] if impact is not provided');
    is($eco_event->event_name, 'Not Given', 'has the default event name if not given');
};

# subtest save_event_to_chronicle => sub {
#     my $today        = Date::Utility->new;
#     my $release_date = Date::Utility->new($today->epoch + 3600);
#     my $event        = BOM::MarketData::EconomicEvent->new({
#         symbol        => 'USD',
#         release_date  => $release_date,
#         source        => 'forexfactory',
#         event_name    => 'my_test_name',
#         recorded_date => $today,
#     });
#     lives_ok { $event->save } 'save didn\'t die';
#     my $dm   = BOM::MarketData::Fetcher::EconomicEvent->new;
#     my @docs = $dm->get_latest_events_for_period({
#         from         => $release_date,
#         to           => $release_date
#     });
#     ok scalar @docs > 0, 'document saved';
# };

 1;
