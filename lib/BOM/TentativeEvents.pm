package BOM::TentativeEvents;

use strict;
use warnings;

use BOM::Platform::Chronicle;
use BOM::Backoffice::Request;
use Quant::Framework::EconomicEventCalendar;

sub _get_tentative_events {

    my $tentative_events = Quant::Framework::EconomicEventCalendar->new({
            chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        }
        )->get_tentative_events
        || {};

    return $tentative_events;
}

sub generate_tentative_events_form {

    my $args   = shift;
    my $events = _get_tentative_events;
    my @events =
        sort { $a->{estimated_release_date} <=> $b->{estimated_release_date} }
        grep { Date::Utility->new($_->{estimated_release_date})->is_after(Date::Utility->new->minus_time_interval('1d')) } map {
        my $event = $events->{$_};
        $event->{release_date} = Date::Utility->new($event->{estimated_release_date});
        $event->{date}         = $event->{release_date}->date_ddmmmyyyy;
        $event->{blankout}     = Date::Utility->new($event->{blankout})->time_hhmm if $event->{blankout};
        $event->{blankout_end} = Date::Utility->new($event->{blankout_end})->time_hhmm if $event->{blankout_end};
        $event;
        } keys %$events;
    my $form = '';
    BOM::Backoffice::Request::template->process(
        'backoffice/economic_tentative_event_forms.html.tt',
        {
            ee_upload_url => $args->{upload_url},
            events        => \@events
        },
        $form
    ) || die BOM::Backoffice::Request::template->error;

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

    return "Tentative events not found in chronicle" unless $events->{$params->{id}};

    my $existing = $events->{$params->{id}};
    my $rd       = Date::Utility->new($existing->{estimated_release_date});
    my $shift    = $params->{tentative_event_shift};
    $shift = 0 if not $shift or $shift eq '';

    $existing->{blankout}              = $rd->plus_time_interval("$b1[0]h$b1[1]m")->epoch;
    $existing->{blankout_end}          = $rd->plus_time_interval("$b2[0]h$b2[1]m")->epoch;
    $existing->{tentative_event_shift} = $shift;

    my $diff = $existing->{blankout_end} - $existing->{blankout};
    return "Blackout start and Blackout end must be 2 hours apart. E.g. 5pm - 7pm" if ($diff != 7200);

    my $update = Quant::Framework::EconomicEventCalendar->new({
            recorded_date    => Date::Utility->new(),
            chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
        })->update($existing);
    return $update ? 1 : 0;
}

1;
