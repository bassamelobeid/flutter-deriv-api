package BOM::EconomicEventTool;

use strict;
use warnings;

use Date::Utility;
use Quant::Framework::EconomicEventCalendar;
use Volatility::Seasonality;
use BOM::Platform::Chronicle;
use BOM::MarketData qw(create_underlying_db);
use LandingCompany::Offerings qw(get_offerings_flyby);
use JSON qw(to_json);
use List::Util qw(first);
use BOM::Backoffice::Request;
use BOM::MarketDataAutoUpdater::Forex;

use File::ShareDir;
use YAML::XS qw(LoadFile);

my $economic_event_categories = LoadFile(File::ShareDir::dist_file('Volatility-Seasonality', 'economic_event_categories.yml'));

sub get_economic_events_for_date {
    my $date = shift;

    return _err('Date is undefined') unless $date;
    my @events = map { get_info($_) } @{_get_economic_events(Date::Utility->new($date))};

    return {events => \@events};
}

sub generate_economic_event_tool {
    my $url = shift;

    my @events = map { get_info($_) } @{_get_economic_events()};
    my $today  = Date::Utility->new->truncate_to_day;
    my @dates  = map { $today->plus_time_interval($_ . 'd')->date } (0 .. 6);

    my @deleted_events = map { human_readable_date($_) } values _get_deleted_events();

    my $unlisted_events = check_unlisted_events(\@events);

    return BOM::Backoffice::Request::template->process(
        'backoffice/economic_event_forms.html.tt',
        {
            ee_upload_url   => $url,
            events          => \@events,
            dates           => \@dates,
            deleted_events  => \@deleted_events,
            unlisted_events => $unlisted_events,
        },
    ) || die BOM::Backoffice::Request::template->error;
}

sub check_unlisted_events {
    my $events = shift;

    my @unlisted_events;

    foreach my $event (@$events) {
        my $pattern = $event->{event_name};
        $pattern =~ s/\s+/_/g;
        my @matches = grep { /$pattern/ } keys %$economic_event_categories;
        push @unlisted_events, $event if not scalar(@matches);
    }
    return \@unlisted_events;
}

sub human_readable_date {
    my $event = shift;

    $event->{release_date} = Date::Utility->new($event->{release_date})->datetime if $event->{release_date};

    return $event;
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
    $event->{info} = \@by_symbols;
    $event->{release_date} = Date::Utility->new($event->{release_date})->datetime if $event->{release_date};

    return $event;
}

sub delete_by_id {
    my $id = shift;

    return _err("ID is not found.") unless ($id);

    my $ref = BOM::Platform::Chronicle::get_chronicle_reader()->get('economic_events', 'economic_events');
    my @existing = @{$ref->{events}};

    my $to_delete = first { $_->{id} eq $id } @existing;

    my $ee = Quant::Framework::EconomicEventCalendar->new(
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
    );

    my $deleted = $ee->delete_event({
        id => $id,
        %$to_delete
    });

    _regenerate($ee->get_economic_events_calendar);

    return _err('Economic event not found with [' . $id . ']') unless $deleted;

    human_readable_date($to_delete);

    return {
        id => $deleted,
        %$to_delete
    };
}

sub update_by_id {
    my $args = shift;

    return _err("ID is not found.") unless $args->{id};
    return _err("Custom magnitude is not provided.") unless exists $args->{custom_magnitude};

    my $ref = BOM::Platform::Chronicle::get_chronicle_reader()->get('economic_events', 'economic_events');
    my @existing = @{$ref->{events}};

    if (my $to_update = first { $_->{id} eq $args->{id} } @existing) {
        $to_update->{custom_magnitude} = $args->{custom_magnitude};
        Quant::Framework::EconomicEventCalendar->new({
                events           => $ref->{events},
                recorded_date    => Date::Utility->new,
                chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
            })->save;
        _regenerate($ref->{events});
        my $new_info = get_info($to_update);
        return {
            id       => $args->{id},
            new_info => $new_info->{info},
        };
    } else {
        return _err('Did not find event with id: ' . $args->{id});
    }
}

sub restore_by_id {
    my $args = shift;

    return _err("ID is not found.") unless $args->{id};

    my $deleted_events = _get_deleted_events();

    my $to_restore = $deleted_events->{$args->{id}};

    return _err('Economic event not found with [' . $args->{id} . ']') unless $to_restore;

    my $ee = Quant::Framework::EconomicEventCalendar->new({
        recorded_date    => Date::Utility->new,
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
    });
    $ee->save_new($to_restore);

    _regenerate($ee->get_economic_events_calendar);

    my $new_info = get_info($to_restore);

    my $unlisted = check_unlisted_events([$to_restore]);
    $to_restore->{unlisted} = 1 if scalar(@$unlisted);

    return {
        id       => $args->{id},
        new_info => $new_info->{info},
        %$to_restore
    };
}

sub save_new_event {
    my $args = shift;

    my $today = Date::Utility->new->truncate_to_day->epoch;
    if ($args->{is_tentative}) {
        return _err('Must specify estimated announcement date for tentative events') if not $args->{estimated_release_date};
        return _err('Estimated release date too old') if Date::Utility->new($args->{estimated_release_date})->epoch < $today;
    } else {
        return _err('Must specify announcement date for economic events') if not $args->{release_date};
        return _err('Release date too old') if Date::Utility->new($args->{release_date})->epoch < $today;
    }

    $args->{release_date} = Date::Utility->new($args->{release_date})->epoch if $args->{release_date};
    $args->{estimated_release_date} = Date::Utility->new($args->{estimated_release_date})->truncate_to_day->epoch
        if $args->{estimated_release_date};

    my $ref          = BOM::Platform::Chronicle::get_chronicle_reader()->get('economic_events', 'economic_events');
    my @events       = @{$ref->{events}};
    my $new_event_id = Quant::Framework::EconomicEventCalendar::_generate_id($args);
    my @duplicate    = grep { $_->{id} eq $new_event_id } @events;

    if (@duplicate) {
        return _err('Identical event exists. Economic event not saved');
    } else {
        push @{$ref->{events}}, $args;
        Quant::Framework::EconomicEventCalendar->new({
                recorded_date    => Date::Utility->new,
                chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
            })->save_new($args);
        _regenerate($ref->{events});

    }

    return BOM::EconomicEventTool::get_info($args);
}

sub _regenerate {
    my $events = shift;

    # update economic events impact curve with the newly added economic event
    Volatility::Seasonality::generate_economic_event_seasonality({
        underlying_symbols => [create_underlying_db->symbols_for_intraday_fx],
        economic_events    => $events,
        chronicle_writer   => BOM::Platform::Chronicle::get_chronicle_writer(),
    });

    return;
}

sub _get_economic_events {
    my $date = shift;

    my $eec = Quant::Framework::EconomicEventCalendar->new(
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
    );
    return $eec->list_economic_events_for_date($date) // [];
}

sub _get_deleted_events {

    my $eec = Quant::Framework::EconomicEventCalendar->new(
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
    );
    return $eec->get_deleted_events() // [];
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
