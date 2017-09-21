package BOM::Backoffice::EconomicEventTool;

use strict;
use warnings;

use BOM::Platform::Chronicle;
use BOM::MarketData qw(create_underlying_db);
use BOM::Backoffice::Request;
use BOM::MarketDataAutoUpdater::Forex;

use Quant::Framework::EconomicEventCalendar;
use Volatility::Seasonality;
use LandingCompany::Offerings qw(get_offerings_flyby);
use Date::Utility;
use JSON qw(to_json);
use List::Util qw(first);

sub get_economic_events_for_date {
    my $date = shift;

    return _err('Date is undefined') unless $date;
    $date = Date::Utility->new($date);

    my $eec             = _eec();
    my $from            = $date->truncate_to_day;
    my $to              = $from->plus_time_interval('23h59m59s');
    my $economic_events = $eec->get_latest_events_for_period({
        from => $from,
        to   => $to,
    });

    my @events = map { get_info($_) } @$economic_events;
    my @deleted_events = map { get_info($_) } (values %{$eec->_get_deleted()});

    return {
        categorized_events => to_json(\@events),
        deleted_events     => to_json(\@deleted_events),
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
    $event->{info}            = \@by_symbols;
    $event->{release_date}    = Date::Utility->new($event->{release_date})->datetime;
    $event->{not_categorized} = !is_categorized($event);

    return $event;
}

sub delete_by_id {
    my $id = shift;

    return _err("ID is not found.") unless ($id);

    my $eec = _eec();

    my $deleted = $eec->delete_event({
        id => $id,
    });

    return _err('Economic event not found with [' . $id . ']') unless $deleted;

    _regenerate($eec->get_all_events());

    return get_info($deleted);
}

sub update_by_id {
    my $args = shift;

    return _err("ID is not found.") unless $args->{id};

    if ($args->{custom_magnitude_indirect_list} && !$args->{custom_magnitude_indirect}) {
        return _err('Please specify magnitude for indirect underlying pairs');
    }

    unless (exists $args->{custom_magnitude_direct} || exists $args->{custom_magnitude_indirect}) {
        return _err('Please specify magnitude to update');
    }

    my $eec     = _eec();
    my $updated = $eec->update_event($args);

    return _err('Did not find event with id: ' . $args->{id}) unless $updated;

    _regenerate($eec->get_all_events());

    return get_info($updated);
}

sub save_new_event {
    my $args = shift;

    if (not $args->{release_date}) {
        return _err('Must specify announcement date for economic events');
    }

    $args->{release_date} = Date::Utility->new($args->{release_date})->epoch if $args->{release_date};

    my $eec   = _eec();
    my $added = $eec->add_event($args);

    return _err('Identical event exists. Economic event not saved') unless $added;

    _regenerate($eec->get_all_events());

    return get_info($added);
}

sub restore_by_id {
    my $id = shift;

    my $eec = _eec();

    my $restored = $eec->restore_event($id);

    return _err('Failed to restore event.') unless $restored;

    _regenerate($eec->get_all_events());

    return get_info($restored);
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

sub _eec {
    return Quant::Framework::EconomicEventCalendar->new(
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
    );
}

1;
