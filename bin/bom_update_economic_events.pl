#!/usr/bin/perl

package BOM::System::Script::UpdateEconomicEvents;

use Moose;
with 'App::Base::Script';
with 'BOM::Utility::Logging';

use BOM::MarketData::Fetcher::EconomicEvent;
use ForexFactory;
use BOM::MarketData::EconomicEvent;
use BOM::Platform::Runtime;
use Date::Utility;
use BOM::Utility::Log4perl;
use DataDog::DogStatsd::Helper qw(stats_gauge);
use JSON;
use Path::Tiny;
use BOM::System::Chronicle;

BOM::Utility::Log4perl::init_log4perl_console;

sub documentation { return 'This script runs economic events update from forex factory at 00:00 GMT'; }

sub script_run {
    my $self = shift;

    die 'Script only to run on master servers.' if (not BOM::Platform::Runtime->instance->hosts->localhost->has_role('master_live_server'));
    my $now = Date::Utility->new;
    my $dm  = BOM::MarketData::Fetcher::EconomicEvent->new();

    my @messages;
    my $parser          = ForexFactory->new();
    my $events_received = $parser->extract_economic_events;

    stats_gauge('economic_events_updates',scalar(@$events_received));

    my $file_timestamp = Date::Utility->new->date_yyyymmdd;

    foreach my $event_param (@$events_received) {
        my $eco = BOM::MarketData::EconomicEvent->new($event_param);
        $eco->save;

        $event_param->{release_date}  = $event_param->{release_date}->epoch;
        $event_param->{recorded_date} = Date::Utility->new->epoch;

        Path::Tiny::path("/feed/economic_events/$file_timestamp")->append(time . ' ' . JSON::to_json($event_param)."\n");
        BOM::System::Chronicle->_redis_write->zadd('ECONOMIC_EVENTS' , $event_param->{release_date}, JSON::to_json($event_param));
        BOM::System::Chronicle->_redis_write->zadd('ECONOMIC_EVENTS_TRIMMED' , $event_param->{release_date}, JSON::to_json($event_param));

    }

    # Removing older events for chronicle. This trimmed version can be use in back pricing if pricing code changes.
    BOM::System::Chronicle->_redis_write->zremrangebyscore("ECONOMIC_EVENTS_TRIMMED" , 0, Date::Utility->new->epoch - 2 * 24 * 3600 );
    BOM::System::Chronicle::add('economic_events' , '', JSON::to_json(BOM::System::Chronicle->_redis_write->zrangebyscore("ECONOMIC_EVENTS_TRIMMED" , 0, "+inf")) );


    my $num_events_saved  = scalar(@$events_received);

    stats_gauge('economic_events_saved',$num_events_saved );

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
