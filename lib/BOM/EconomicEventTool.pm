package BOM::EconomicEventTool;

use strict;
use warnings;

use Quant::Framework::EconomicEventCalendar;
use Volatility::Seasonality;
use BOM::Platform::Chronicle;
use LandingCompany::Offerings qw(get_offerings_flyby);
use JSON qw(to_json);
use List::Util qw(first);
use BOM::Backoffice::Request;

sub generate_economic_event_tool {
    my $url = shift;

    my @events = map { get_info($_) } @{_get_economic_events()};

    return BOM::Backoffice::Request::template->process(
        'backoffice/economic_event_forms.html.tt',
        {
            ee_upload_url => $url,
            events        => \@events,
        },
    ) || die BOM::Backoffice::Request::template->error;
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

    my $deleted = Quant::Framework::EconomicEventCalendar->new(
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
    )->delete_event({id => $id});

    return _err('Economic event not found with [' . $id . ']') unless $deleted;
    return {id => $deleted};
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
        my $new_info = get_info($to_update);
        return {
            id       => $args->{id},
            new_info => $new_info->{info},
        };
    } else {
        return _err('Did not find event with id: ' . $args->{id});
    }
}

sub _err {
    return {error => 'ERR: ' . shift};
}

sub _get_economic_events {
    my $eec = Quant::Framework::EconomicEventCalendar->new(
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
    );
    return $eec->list_economic_events_for_date() // [];
}

my @symbols;

sub _get_affected_underlying_symbols {
    return @symbols if @symbols;

    my $fb = get_offerings_flyby();
    @symbols = $fb->query({submarket => 'major_pairs'}, ['underlying_symbol']);
    return @symbols;
}

1;
