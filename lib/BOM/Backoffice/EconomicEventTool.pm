package BOM::Backoffice::EconomicEventTool;

use strict;
use warnings;

use Date::Utility;
use Quant::Framework::EconomicEvent::Scheduled;
use Quant::Framework::EconomicEvent::Tentative;
use Volatility::Seasonality;
use BOM::Platform::Chronicle;
use BOM::MarketData qw(create_underlying_db);
use LandingCompany::Offerings qw(get_offerings_flyby);
use JSON qw(to_json);
use List::Util qw(first);
use BOM::Backoffice::Request;
use BOM::MarketDataAutoUpdater::Forex;

sub _ees {
    return Quant::Framework::EconomicEvent::Scheduled->new(
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
    );
}

sub _eet {
    return Quant::Framework::EconomicEvent::Tentative->new(
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
    );
}

sub get_economic_events_for_date {
    my $date = shift;

    return _err('Date is undefined') unless $date;
    $date = Date::Utility->new($date);

    my $ees             = _ees();
    my $from            = $date->truncate_to_day;
    my $to              = $from->plus_time_interval('23h59m59s');
    my $economic_events = $ees->get_latest_events_for_period({
        from => $from,
        to   => $to,
    });

    my @events               = map  { get_info($_) } @$economic_events;
    my @uncategorized_events = grep { !is_categorized($_) } @$economic_events;
    my @deleted_events       = map  { get_info($_) } (values %{$ees->_get_deleted()});

    return {
        categorized_events   => to_json(\@events),
        uncategorized_events => to_json(\@uncategorized_events),
        deleted_events       => to_json(\@deleted_events),
    };
}

sub generate_economic_event_tool {
    my $url = shift;

    my $events = get_economic_events_for_date(Date::Utility->new);
    my $today  = Date::Utility->new->truncate_to_day;
    my @dates  = map { $today->plus_time_interval($_ . 'd')->date } (0 .. 6);

    return BOM::Backoffice::Request::template->process(
        'backoffice/economic_event_forms.html.tt',
        +{
            ee_upload_url => $url,
            dates         => \@dates,
            %$events,
        },
    ) || die BOM::Backoffice::Request::template->error;
}

sub is_categorized {
    my $event = shift;

    $event->{event_name} =~ s/\s/_/g;
    my @categories = keys %{Volatility::Seasonality::get_economic_event_categories()};
    return 1 if first { $_ =~ /$event->{event_name}/ } @categories;
    return 0;
}

# get the calibration magnitude and duration factor of the given economic event, if any.
sub get_info {
    my $event = shift;

    my @by_symbols;
    foreach my $symbol (_get_affected_underlying_symbols()) {
        my %cat = map { $symbol => 'magnitude: ' . int($_->{magnitude}) . ' duration: ' . int($_->{duration}) . 's' }
            @{Volatility::Seasonality::categorize_events($symbol, [$event])};
        push @by_symbols, to_json(\%cat) if %cat;
    }
    $event->{info}         = \@by_symbols;
    $event->{release_date} = Date::Utility->new($event->{release_date})->datetime;

    return $event;
}

sub delete_by_id {
    my $id = shift;

    return _err("ID is not found.") unless ($id);

    my $ees = _ees();

    my $deleted = $ees->delete_event({
        id => $id,
    });

    return _err('Economic event not found with [' . $id . ']') unless $deleted;

    _regenerate($ees->get_economic_events_calendar);

    return $deleted;
}

sub update_by_id {
    my $args = shift;

    return _err("ID is not found.") unless $args->{id};
    return _err("Custom magnitude is not provided.") unless exists $args->{custom_magnitude};

    my $ees     = _ees();
    my $updated = $ees->update_event($args);

    return _err('Did not find event with id: ' . $args->{id}) unless $updated;

    _regenerate($ees->get_all_events());

    return {
        is       => $updated->{id},
        new_info => get_info($updated),
    };
}

sub save_new_event {
    my $args = shift;

    if ($args->{is_tentative} and not $args->{estimated_release_date}) {
        return _err('Must specify estimated announcement date for tentative events');
    }

    if (not $args->{release_date} and not $args->{is_tentative}) {
        return _err('Must specify announcement date for economic events');
    }

    $args->{release_date} = Date::Utility->new($args->{release_date})->epoch if $args->{release_date};
    $args->{estimated_release_date} = Date::Utility->new($args->{estimated_release_date})->truncate_to_day->epoch
        if $args->{estimated_release_date};

    my $ee_object = $args->{is_tentative} ? _eet() : _ees();
    my $added = $ee_object->add_event($args);

    return _err('Identical event exists. Economic event not saved') unless $added;

    _regenerate($ee_object->get_all_events()) if $ee_object->symbol eq 'scheduled';

    return get_info($added);
}

sub _regenerate {
    my $events = shift;

    # update economic events impact curve with the newly added economic event
    Volatility::Seasonality::generate_economic_event_seasonality({
        underlying_symbols => [create_underlying_db->symbols_for_intraday_fx],
        economic_events    => $events,
        chronicle_writer   => BOM::Platform::Chronicle::get_chronicle_writer(),
    });

    # refresh intradayfx cache to to use new economic events impact curve
    BOM::MarketDataAutoUpdater::Forex->new()->warmup_intradayfx_cache();

    return;
}

sub _err {
    return {error => 'ERR: ' . shift};
}

my @symbols;

sub _get_affected_underlying_symbols {
    return @symbols if @symbols;

    my $fb = get_offerings_flyby();
    @symbols = $fb->query({submarket => 'major_pairs'}, ['underlying_symbol']);
    return @symbols;
}

1;
