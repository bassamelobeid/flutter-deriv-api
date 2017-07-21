package BOM::EconomicEventTool;

use strict;
use warnings;

use Quant::Framework::EconomicEventCalendar;
use Volatility::Seasonality;
use BOM::Platform::Chronicle;
use LandingCompany::Offerings qw(get_offerings_flyby);
use JSON qw(to_json);
use BOM::Backoffice::Request;

sub _get_economic_events {
    my $eec = Quant::Framework::EconomicEventCalendar->new(
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
    );
    return $eec->list_economic_events_for_date() // [];
}

sub generate_economic_event_tool {
    my $url = shift;

    my $events    = _get_economic_events();
    my $fb        = get_offerings_flyby();
    my @u_symbols = $fb->query({submarket => 'major_pairs'}, ['underlying_symbol']);
    my %affected_symbol_by_event;

    foreach my $event (@$events) {
        my @by_symbols = grep { $_ } map {
            my $cat = Volatility::Seasonality::categorize_events($_, [$event]);
            (@$cat) ? to_json({$_ => $cat}) : '';
        } @u_symbols;
        $event->{info}         = \@by_symbols;
        $event->{release_date} = Date::Utility->new($event->{release_date})->datetime;
    }

    return BOM::Backoffice::Request::template->process(
        'backoffice/economic_event_forms.html.tt',
        {
            ee_upload_url => $url,
            events        => $events,
        },
    ) || die BOM::Backoffice::Request::template->error;
}

1;
