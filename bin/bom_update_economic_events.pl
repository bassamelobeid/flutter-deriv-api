#!/etc/rmg/bin/perl

package BOM::MarketDataAutoUpdater::UpdateEconomicEvents;

use Moose;
with 'App::Base::Script';

use ForexFactory;
use Volatility::Seasonality;
use Quant::Framework::EconomicEventCalendar;
use BOM::MarketData qw(create_underlying_db);
use Volatility::Seasonality;
use BOM::Platform::Runtime;
use Date::Utility;
use DataDog::DogStatsd::Helper qw(stats_gauge);
use JSON;
use Path::Tiny;
use BOM::System::Chronicle;
use Try::Tiny;
use List::Util qw(first uniq);

sub documentation { return 'This script runs economic events update from forex factory at 00:00 GMT'; }

sub script_run {
    my $self = shift;

    my @messages;
    my $parser = ForexFactory->new();

    #read economic events for one week (7-days) starting from 4 days back, so in case of a Monday which
    #has its last Friday as a holiday, we will still have some events in the cache.
    my $events_received = $parser->extract_economic_events(2, Date::Utility->new()->minus_time_interval('4d'));

    stats_gauge('economic_events_updates', scalar(@$events_received));

    my $file_timestamp = Date::Utility->new->date_yyyymmdd;

    #this will be an array of all extracted economic events. Later we will store

    foreach my $event_param (@$events_received) {
        $event_param->{recorded_date} = Date::Utility->new->epoch;
        Path::Tiny::path("/feed/economic_events/$file_timestamp")->append(time . ' ' . JSON::to_json($event_param) . "\n");
    }

    try {

        my $tentative_count = grep { $_->{is_tentative} } @$events_received;

        Quant::Framework::EconomicEventCalendar->new({
                events           => $events_received,
                recorded_date    => Date::Utility->new(),
                chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
            })->save;

        print "stored " . (scalar @$events_received) . " events ($tentative_count are tentative events) in chronicle...\n";

        my @underlying_symbols = create_underlying_db->symbols_for_intraday_fx;
        my $qfs                = Volatility::Seasonality->new(
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
        );

        foreach my $symbol (@underlying_symbols) {
            $qfs->generate_economic_event_seasonality({
                underlying_symbol => $symbol,
                economic_events   => $events_received
            });
        }

        print "generated economic events impact curves for " . scalar(@underlying_symbols) . " underlying symbols.";

    }
    catch {
        print 'Error occured while saving events: ' . $_;
    };

    my $num_events_saved = scalar(@$events_received);

    stats_gauge('economic_events_saved', $num_events_saved);

    if (not $num_events_saved > 0) {
        print 'No economic event is saved on chronicle today. Please check';
    }

    return 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

package main;

exit BOM::MarketDataAutoUpdater::UpdateEconomicEvents->new()->run();
