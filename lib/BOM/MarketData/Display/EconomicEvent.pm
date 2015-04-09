package BOM::MarketData::Display::EconomicEvent;

=head1 NAME

BOM::MarketData::Display::EconomicEvent

=cut

=head1 DESCRIPTION

Handles display of economic events in the backoffice.

    my $display = BOM::MarketData::Display::EconomicEvent->new();
    $display->events_for_today() # displays economic events that will happen today in table format
    $display->all_events_saved_for_date() # displays all economic events that were saved today

=cut

use Moose;
use Carp;

use BOM::Platform::Runtime;
use BOM::Platform::Context;
use BOM::MarketData::Fetcher::EconomicEvent;

has data_mapper => (
    is      => 'ro',
    isa     => 'BOM::MarketData::Fetcher::EconomicEvent',
    default => sub { BOM::MarketData::Fetcher::EconomicEvent->new() },
);

=head2 events_for_today

Returns economic events that will happen today in a table format.

=cut

sub events_for_today {
    my $self = shift;

    my $start_of_day = Date::Utility->new()->truncate_to_day;
    my $end_of_day   = Date::Utility->new($start_of_day->epoch + 86400);

    my $dm       = $self->data_mapper;
    my $events_1 = $dm->get_latest_events_for_period({
        from   => $start_of_day,
        to     => $end_of_day,
        source => 'bloomberg',
    });

    my $events_2 = $dm->get_latest_events_for_period({
        from   => $start_of_day,
        to     => $end_of_day,
        source => 'forexfactory',
    });

    my @events = (@$events_1, @$events_2);

    my @sorted_events =
        sort { $a->release_date->epoch <=> $b->release_date->epoch || $a->symbol cmp $b->symbol } @events;

    my @rows = map { {
            event_name    => $_->event_name,
            recorded_date => $_->recorded_date->date,
            release_date  => $_->release_date->datetime,
            symbol        => $_->symbol,
            impact        => $_->impact,
            source        => $_->source,
        }
    } @sorted_events;

    my $events_content;
    BOM::Platform::Context::template->process(
        'backoffice/container/economic_events.html.tt',
        {
            rows => \@rows,
        },
        \$events_content
    ) || die BOM::Platform::Context::template->error;

    return $events_content;
}

=head2 all_events_saved_for_date

Returns events saved on a particular day in a table format.

=cut

sub all_events_saved_for_date {
    my ($self, $date) = @_;

    my $dm     = $self->data_mapper;
    my $events = $dm->get_events_saved_on_date($date);
    my @rows   = map { {
            event_name    => $_->event_name,
            recorded_date => $_->recorded_date->date_ddmmmyyyy,
            release_date  => $_->release_date->datetime,
            symbol        => $_->symbol,
            impact        => $_->impact,
            source        => $_->source,
        }
    } @$events;

    my $events_content;
    BOM::Platform::Context::template->process(
        'backoffice/container/economic_events.html.tt',
        {
            rows => \@rows,
        },
        \$events_content
    ) || die BOM::Platform::Context::template->error;

    return $events_content;
}

sub economic_event_forms {
    my ($self, $action_url) = @_;

    my $cron_runner;
    BOM::Platform::Context::template->process(
        'backoffice/economic_event_forms.html.tt',
        {
            ee_upload_url => $action_url,
        },
        \$cron_runner
    ) || die BOM::Platform::Context::template->error;

    return $cron_runner;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
