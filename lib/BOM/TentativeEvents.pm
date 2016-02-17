package BOM::TentativeEvents;

use strict;
use warnings;

use BOM::System::Chronicle;
use BOM::MarketData::EconomicEventCalendar;

sub _get_tentative_events {

    my $tentative_events = BOM::MarketData::EconomicEventCalendar->new->get_tentative_events || {};

    return $tentative_events;
}

sub generate_tentative_events_form {

    my $args   = shift;
    my $events = _get_tentative_events;
    my @events = sort { $a->{release_date}->{epoch} <=> $b->{release_date}->{epoch} } map {
        my $event = $events->{$_};
        $event->{release_date} = Date::Utility->new($event->{release_date});
        $event->{date}         = $event->{release_date}->date_ddmmmyyyy;
        $event->{blankout}     = Date::Utility->new($event->{blankout})->time_hhmm if $event->{blankout};
        $event->{blankout_end} = Date::Utility->new($event->{blankout_end})->time_hhmm if $event->{blankout_end};
        $event;
    } keys %$events;
    my $form = '';
    BOM::Platform::Context::template->process(
        'backoffice/economic_tentative_event_forms.html.tt',
        {
            ee_upload_url => $args->{upload_url},
            events        => \@events
        },
        $form
    ) || die BOM::Platform::Context::template->error;

    return $form;
}

sub update_event {

    my $params = shift;

    my $events = _get_tentative_events;

    if (!$params->{id}) {
        return 'Event\'s Id not provided';
    }

    my (@b1, @b2);
    if ($params->{blankout} !~ /^(\d+):(\d+)$/ || $1 < 0 || $1 > 23 || $2 < 0 || $2 > 59) {
        return 'Blankout start time not correct!';
    } else {
        @b1 = ($1, $2);
    }
    if ($params->{blankout_end} !~ /^(\d+):(\d+)$/ || $1 < 0 || $1 > 23 || $2 < 0 || $2 > 59) {
        return 'Blankout end time not correct!';
    } else {
        @b2 = ($1, $2);
    }

    my @updated_events;
    foreach my $id (keys %$events) {
        if ($id eq $params->{id}) {

            my $blankout = Date::Utility->new($events->{$id}->{release_date});
            $events->{$id}->{blankout}     = Date::Utility->new($events->{$id}->{release_date})->plus_time_interval("$b1[0]h$b1[1]m")->epoch;
            $events->{$id}->{blankout_end} = Date::Utility->new($events->{$id}->{release_date})->plus_time_interval("$b2[0]h$b2[1]m")->epoch;
            if ($events->{$id}->{blankout} > $events->{$id}->{blankout_end}) {
                return 'Blankout end time should be after blankout start time!';
            }
            push @updated_events, $events->{$id};
            last;
        }
    }

    return BOM::MarketData::EconomicEventCalendar->new({
            events        => \@updated_events,
            recorded_date => Date::Utility->new(),
        })->update ? 1 : 0;
}

1;
