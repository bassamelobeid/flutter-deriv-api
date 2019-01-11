package BOM::MarketDataAutoUpdater::UpdateEconomicEvents;

use Moose;

use ForexFactory;
use Bloomberg::EconomicEvents;
use Bloomberg::FileDownloader;
use BOM::MarketData qw(create_underlying create_underlying_db);
use BOM::Config::Runtime;
use Date::Utility;
use DataDog::DogStatsd::Helper qw(stats_gauge);
use JSON::MaybeXS;
use Path::Tiny;
use BOM::Config::Chronicle;
use Try::Tiny;
use List::Util qw(first uniq max);
use Sys::Info;
use Quant::Framework::EconomicEventCalendar;
use Quant::Framework::VolSurface::Delta;
use Volatility::EconomicEvents;

sub run {
    my $self = shift;

    my $ff                 = get_events_from_forex_factory();
    my $bb                 = get_events_from_bloomberg_data_license();
    my $consolidate_events = consolidate_events($ff, $bb);
    try {
        Quant::Framework::EconomicEventCalendar->new(
            events           => $consolidate_events,
            recorded_date    => Date::Utility->new,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        )->save;

        print "stored " . (scalar @$consolidate_events) . "\n";

        my @underlying_symbols = create_underlying_db->symbols_for_intraday_fx;

        Volatility::EconomicEvents::generate_variance({
            underlying_symbols => \@underlying_symbols,
            economic_events    => $consolidate_events,
            chronicle_writer   => BOM::Config::Chronicle::get_chronicle_writer(),
            strict             => 1,
        });

        print "generated economic events impact curves for " . scalar(@underlying_symbols) . " underlying symbols.\n";
    }
    catch {
        print 'Error occured while saving events: ' . $_ . "\n";
    };

    my $num_events_saved = scalar(@$consolidate_events);

    stats_gauge('economic_events_saved', $consolidate_events);

    if (not $num_events_saved > 0) {
        print "No economic event is saved on chronicle today. Please check.\n";
    }

    return 0;
}

sub get_events_from_forex_factory {

    my $parser = ForexFactory->new();

    # reads 3 weeks of economic events data
    my $starting_date = Date::Utility->today;
    my (@multiweek_events, $errors);
    try {
        @multiweek_events =
            map { @{$parser->extract_economic_events($_->[1], $starting_date->plus_time_interval($_->[0] * 7 . 'd'))} } ([0, 1], [2, 0]);
    }
    catch {
        $errors = $_;
    };

    if ($errors) {
        return \@multiweek_events;

    }
    my $events_received = \@multiweek_events;

    stats_gauge('economic_events_updates', scalar(@$events_received), {tags => ['tag: ff']});

    my $file_timestamp = Date::Utility->new->date_yyyymmdd;

    foreach my $event_param (@$events_received) {
        $event_param->{recorded_date} = Date::Utility->new->epoch;
        Path::Tiny::path("/feed/economic_events/$file_timestamp")->append_utf8(time . ' FF  ' . JSON::MaybeXS->new->encode($event_param) . "\n");
    }

    return $events_received;
}

sub get_events_from_bloomberg_data_license {

    my $parser = Bloomberg::EconomicEvents->new();
    my ($events_received, $errors);
    try {
        my @files = Bloomberg::FileDownloader->new->grab_files({
            file_type => 'economic_events',
        });
        # reads 3 weeks of economic events data
        my $err;
        ($events_received, $err) = $parser->parse_data_for($files[0], 3, Date::Utility->new()->minus_time_interval('4d'));
    }
    catch {
        $errors = $_;

    };
    if ($errors) {
        return $events_received;

    }
    stats_gauge('economic_events_updates', scalar(@$events_received), {tags => ['tag: bb']});

    my $file_timestamp = Date::Utility->new->date_yyyymmdd;

    foreach my $event_param (@$events_received) {
        $event_param->{recorded_date} = Date::Utility->new->epoch;
        Path::Tiny::path("/feed/economic_events/$file_timestamp")->append_utf8(time . ' BB  ' . JSON::MaybeXS->new->encode($event_param) . "\n");
    }

    return $events_received;
}

sub consolidate_events {
    my ($ff, $bb) = @_;
    return $ff if (not $bb or (scalar(@$bb) <= 0));
    return $bb if (not $ff or (scalar(@$ff) <= 0));

    my %bb_hash =
        map { my $rd = $_->{release_date} // $_->{estimated_release_date} // 0; my $key = $_->{binary_ticker} . '_' . $rd; $key => $_ }
        grep { defined $_->{binary_ticker} } @$bb;
    my ($match, $unmatch);
    foreach my $ff (grep { $_->{binary_ticker} } @$ff) {
        my $ff_ticker = $ff->{binary_ticker};
        my $rd        = $ff->{release_date} // $ff->{estimated_release_date} // 0;
        my $ff_key    = $ff_ticker . '_' . $rd;
        if ($bb_hash{$ff_key}) {
            $bb_hash{$ff_key}->{impact} = $ff->{impact} if $ff->{impact} > $bb_hash{$ff_key}->{impact};
            $match++;
        } else {
            $unmatch++;
            $bb_hash{$ff_key} = $ff;
        }
    }
    return [sort { $a->{release_date} <=> $b->{release_date} } grep { exists $_->{release_date} } values %bb_hash];

}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
