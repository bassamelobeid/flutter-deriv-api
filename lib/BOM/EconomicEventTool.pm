package BOM::EconomicEventTool;

use strict;
use warnings;

use Quant::Framework::EconomicEventCalendar;
use Volatility::Seasonality;
use BOM::Platform::Chronicle;
use LandingCompany::Offerings qw(get_offerings_flyby);
use JSON qw(to_json);
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

    return _err("Error: ID is not found.") unless ($id);

    my $deleted = Quant::Framework::EconomicEventCalendar->new(
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
    )->delete_event({id => $id});

    return _err('Economic event not found with [' . $id . ']') unless $deleted;
    return {id => $deleted};
}

sub _err {
    return {error => shift};
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
