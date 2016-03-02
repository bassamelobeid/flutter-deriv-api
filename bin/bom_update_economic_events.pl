#!/usr/bin/perl

package BOM::System::Script::UpdateEconomicEvents;

use Moose;
with 'App::Base::Script';
with 'BOM::Utility::Logging';

use BOM::MarketData::Fetcher::EconomicEvent;
use ForexFactory;
use BOM::MarketData::EconomicEventCalendar;
use BOM::Platform::Runtime;
use Date::Utility;
use BOM::Utility::Log4perl;
use DataDog::DogStatsd::Helper qw(stats_gauge);
use JSON;
use Path::Tiny;
use BOM::System::RedisReplicated;
use Try::Tiny;
use List::Util qw(first);

BOM::Utility::Log4perl::init_log4perl_console;

sub documentation { return 'This script runs economic events update from forex factory at 00:00 GMT'; }

sub script_run {
    my $self = shift;

    my @messages;
    my $parser = ForexFactory->new();

    #read economic events for one week (7-days) starting from 4 days back, so in case of a Monday which
    #has its last Friday as a holiday, we will still have some events in the cache.
    my $events_received = $parser->extract_economic_events(0, Date::Utility->new()->minus_time_interval('4d'));

    stats_gauge('economic_events_updates', scalar(@$events_received));

    my $file_timestamp = Date::Utility->new->date_yyyymmdd;

    #this will be an array of all extracted economic events. Later we will store

    foreach my $event_param (@$events_received) {
        $event_param->{release_date}  = $event_param->{release_date}->epoch;
        $event_param->{recorded_date} = Date::Utility->new->epoch;

        Path::Tiny::path("/feed/economic_events/$file_timestamp")->append(time . ' ' . JSON::to_json($event_param) . "\n");
    }

    try {
        #here we need epochs to sort events
        #the sorted array (by release date) in chronicle
        my @all_events = sort { $a->{release_date} <=> $b->{release_date} } @$events_received;

        my $tentative_count = grep {$_->{is_tentative}} @all_events;

        BOM::MarketData::EconomicEventCalendar->new({
                events        => \@all_events,
                recorded_date => Date::Utility->new(),
            })->save;

        print "stored " . (scalar @all_events) . " events ($tentative_count are tentative events) in chronicle...\n";
    }
    catch {
        print 'Error occured while saving events: ' . $_;
    };

    my $num_events_saved = scalar(@$events_received);

    stats_gauge('economic_events_saved', $num_events_saved);

    if (not $num_events_saved > 0) {
        print 'No economic event is saved on couch today. Please check';
    }

    return 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

package main;

exit BOM::System::Script::UpdateEconomicEvents->new()->run();
