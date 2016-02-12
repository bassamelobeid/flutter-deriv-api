package BOM::TentativeEvents;

use strict;
use warnings;

use BOM::System::Chronicle;
use BOM::MarketData::EconomicEventCalendar;

sub _get_tentative_events {

    my $tentative_events = BOM::System::Chronicle::get(EE, EET) || {};
    return $tentative_events;
}

sub generate_tentative_events_form {

    my $events = _get_tentative_events;
    my @events = map { $events->{$_} } keys %$events;

    my $form;
    BOM::Platform::Context::template->process(
        'backoffice/economic_tentative_event_forms.html.tt',
        {
            ee_upload_url    => request()->url_for('backoffice/quant/market_data_mgmt/quant_market_tools_backoffice.cgi'),
            tentative_events => \@events
        },
        $form
    ) || die BOM::Platform::Context::template->error;

    return $form;
}

sub update_event {

    my $params = shift;

    my $events = _get_tentative_events;

    my @updated_events;
    foreach my $id (keys %$events) {
        if ($id eq $params->{id}) {
            if ($params->{blankout} and $params->{blankout} =~ /^(\d+):(\d+)$/ and $1 >= 0 and $1 <= 23 and $2 >= 0 and $2 <= 59) {
                $events->{$id}->{blankout} = $params->{blankout};
            }
            if ($params->{blankout_end} and $params->{blankout_end} =~ /^(\d+):(\d+)$/ and $1 >= 0 and $1 <= 23 and $2 >= 0 and $2 <= 59) {
                $events->{$id}->{blankout_end} = $params->{blankout_end};
            }
            push @updated_events, $events->{$id};
        }
    }

    return BOM::MarketData::EconomicEventCalendar->new({
            events        => \@updated_events,
            recorded_date => Date::Utility->new(),
        })->update;
}
