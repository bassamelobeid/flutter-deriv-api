package BOM::MarketDataAutoUpdater::Script::UpdateEconomicEvents;

use Moose;
with 'App::Base::Script';

use ForexFactory;
use BOM::MarketData qw(create_underlying create_underlying_db);
use BOM::Platform::Runtime;
use Date::Utility;
use DataDog::DogStatsd::Helper qw(stats_gauge);
use JSON::MaybeXS;
use Path::Tiny;
use BOM::Platform::Chronicle;
use Try::Tiny;
use List::Util qw(first uniq max);
use Sys::Info;
use Quant::Framework::EconomicEventCalendar;
use Quant::Framework::VolSurface::Delta;
use Volatility::EconomicEvents;

sub documentation { return 'This script runs economic events update from forex factory at 00:00 GMT'; }

sub script_run {
    my $self = shift;

    my $parser = ForexFactory->new();

    #read economic events for one week (7-days) starting from 4 days back, so in case of a Monday which
    #has its last Friday as a holiday, we will still have some events in the cache.
    my $events_received = $parser->extract_economic_events(1, Date::Utility->new()->minus_time_interval('4d'));

    stats_gauge('economic_events_updates', scalar(@$events_received));

    my $file_timestamp = Date::Utility->new->date_yyyymmdd;

    #this will be an array of all extracted economic events. Later we will store

    foreach my $event_param (@$events_received) {
        $event_param->{recorded_date} = Date::Utility->new->epoch;
        Path::Tiny::path("/feed/economic_events/$file_timestamp")->append(time . ' ' . JSON::MaybeXS->new->encode($event_param) . "\n");
    }

    try {
        Quant::Framework::EconomicEventCalendar->new(
            events           => $events_received,
            recorded_date    => Date::Utility->new,
            chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
        )->save;

        print "stored " . (scalar @$events_received) . "\n";

        my @underlying_symbols = create_underlying_db->symbols_for_intraday_fx;

        Volatility::EconomicEvents::generate_variance({
            underlying_symbols => \@underlying_symbols,
            economic_events    => $events_received,
            chronicle_writer   => BOM::Platform::Chronicle::get_chronicle_writer(),
            strict             => 1,
        });

        print "generated economic events impact curves for " . scalar(@underlying_symbols) . " underlying symbols.\n";
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
