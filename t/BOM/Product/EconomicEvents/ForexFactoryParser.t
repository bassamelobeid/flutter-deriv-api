#!/usr/bin/perl

use strict;
use warnings;

use Test::More (tests => 3);
use Test::NoWarnings;
use Test::Exception;
use BOM::MarketData::Fetcher::EconomicEvent;

use BOM::Test::Runtime qw(:normal);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::MarketData::Fetcher::EconomicEvent;
use ForexFactory;
use Date::Utility;
use BOM::MarketData::EconomicEvent;

my $dm         = BOM::MarketData::Fetcher::EconomicEvent->new;
my $now        = Date::Utility->new;
my $sec_in_day = 86400;

my $events_received = ForexFactory->new->extract_economic_events;
cmp_ok(scalar(@$events_received), '>=', 1, 'At least one event has been retrieved next one week');

foreach my $event_param (@$events_received) {
    my $eco = BOM::MarketData::EconomicEvent->new($event_param);
    $eco->save;
}

my $one_week = $dm->get_events_saved_on_date($now);
my $outwith_next_week =
    grep { $_->release_date->epoch > Date::Utility->new($now->epoch + 7 * $sec_in_day)->epoch and $_->recorded_date->date eq $now->date } @$one_week;
ok(!$outwith_next_week, 'All events are within the next week.');
