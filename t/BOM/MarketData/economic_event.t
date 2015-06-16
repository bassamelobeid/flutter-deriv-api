#!/usr/bin/perl

use Test::More (tests => 4);
use Test::NoWarnings;
use Test::Exception;

use BOM::Test::Runtime qw(:normal);
use BOM::MarketData::Fetcher::EconomicEvent;
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use BOM::MarketData::EconomicEvent;
use BOM::Platform::Runtime;
use Date::Utility;

BOM::Platform::Runtime->instance->app_config->quants->market_data->economic_announcements_source('forexfactory');
my $now = Date::Utility->new;
subtest sanity_check => sub {
    throws_ok { BOM::MarketData::EconomicEvent->new({symbol => 'USD', source => 'forexfactory'}) }
    qr/Attribute \(release_date\) is required/,
        'throws exception if release_date is undef';
    throws_ok { BOM::MarketData::EconomicEvent->new({release_date => '2012-02-12', source => 'forexfactory'}) }
    qr/Attribute \(symbol\) is required/,
        'throws exception if symbol is undef';
    my $new_eco = BOM::MarketData::EconomicEvent->new({
        symbol        => 'USD',
        release_date  => Date::Utility->new(time + 20000),
        recorded_date => Date::Utility->new,
        source        => 'forexfactory',
    });
    isa_ok($new_eco->recorded_date, 'Date::Utility');
    my $eco;
    lives_ok {
        $eco = BOM::MarketData::EconomicEvent->new({
            symbol       => 'USD',
            release_date => time + 5000,
            source       => 'forexfactory',
        });
    }
    'lives if recorded_date is not specified';
    is($eco->impact,     5,           'default to the highest impact value [5] if impact is not provided');
    is($eco->event_name, 'Not Given', 'has the default event name if not given');
};

subtest save_event_to_couch => sub {
    my $today        = Date::Utility->new;
    my $release_date = Date::Utility->new($today->epoch + 3600);
    my $event        = BOM::MarketData::EconomicEvent->new({
        symbol        => 'USD',
        release_date  => $release_date,
        source        => 'forexfactory',
        event_name    => 'my_test_name',
        recorded_date => $today,
    });
    lives_ok { $event->save } 'save didn\'t die';
    my $dm   = BOM::MarketData::Fetcher::EconomicEvent->new;
    my @docs = $dm->retrieve_doc_with_view({
        symbol       => 'USD',
        release_date => $release_date,
        event_name   => 'my_test_name',
    });
    ok scalar @docs > 0, 'document saved';
};

subtest no_duplicate_event => sub {
    my $now    = Date::Utility->new;
    my $params = {
        symbol       => 'USD',
        release_date => $now->epoch + 20000,
        source       => 'forexfactory',
        impact       => 1,
        event_name   => 'test',
    };
    my $event = BOM::MarketData::EconomicEvent->new($params);
    lives_ok { $event->save } 'save event does not die';
    lives_ok { $event->save } 'saves one more time does not die';

    my $dm   = BOM::MarketData::Fetcher::EconomicEvent->new();
    my @docs = $dm->retrieve_doc_with_view({
        symbol       => 'USD',
        release_date => Date::Utility->new($now->epoch + 20000)->datetime_iso8601,
        event_name   => 'test'
    });
    is(scalar @docs, 1, 'no duplicate found');
};

1;
