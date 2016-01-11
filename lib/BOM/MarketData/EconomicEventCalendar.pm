package BOM::MarketData::EconomicEventCalendar;
#Chornicle Economic Event

use BOM::System::Chronicle;

=head1 NAME

BOM::MarketData::EconomicEventCalendar

=head1 DESCRIPTION

Represents an economic event in the financial market
 
     my $eco = BOM::MarketData::EconomicEventCalendar->new({
        recorded_date => $dt,
        events => $arr_events
     });

=cut

use Moose;
extends 'BOM::MarketData';

use Date::Utility;

use BOM::Market::Types;

use constant EE => 'economic_events';

has document => (
    is         => 'rw',
    lazy_build => 1,
);

has symbol => (
    is       => 'ro',
    required => 0,
    default  => EE,
);

=head2 for_date

The date for which we wish data or undef if we want latest copy

=cut

has for_date => (
    is      => 'ro',
    isa     => 'Maybe[Date::Utility]',
    default => undef,
);

has events => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_events {
    my $self = shift;
    return $self->document->{events};
}

=head3

This function is called when loading an EconomicEventCalendar from Chronicle.

=cut

sub _build_document {
    my $self = shift;

    #document is an array of hash
    #each hash represents a single economic event
    my $document = BOM::System::Chronicle::get(EE, EE);

    #extract first event from current document to check whether we need to get back to historical data
    my $events           = $document->{events};
    my $first_event      = $events->[0];
    my $first_event_date = Date::Utility->new($first_event->{release_date});

    if ($self->for_date and $self->for_date->epoch < $first_event_date->epoch) {
        $document = BOM::System::Chronicle::get_for(EE, EE, $self->for_date->epoch);

        $document //= {events => []};
    }

    return $document;
}

around _document_content => sub {
    my $orig = shift;
    my $self = shift;

    #this will contain symbol, date and events
    my $data = {
        %{$self->$orig},
        events => $self->events,
    };

    return $data;
};

=head3 C<< save >>

Saves the calendar into Chronicle

=cut

sub save {
    my $self = shift;

    if (not defined BOM::System::Chronicle::get(EE, EE)) {
        BOM::System::Chronicle::set(EE, EE, {});
    }

    for my $event (@{$self->events}) {
        if (ref($event->{release_date}) eq 'Date::Utility') {
            $event->{release_date} = $event->{release_date}->datetime_iso8601;
        }
    }

    return BOM::System::Chronicle::set(EE, EE, $self->_document_content, $self->recorded_date);
}

sub get_latest_events_for_period {
    my ($self, $period) = @_;

    my $from = Date::Utility->new($period->{from})->epoch;
    my $to   = Date::Utility->new($period->{to})->epoch;

    #get latest events
    my $document = BOM::System::Chronicle::get(EE, EE);

    #extract first event from current document to check whether we need to get back to historical data
    my $events           = $document->{events};
    my $first_event      = $events->[0];
    my $first_event_date = Date::Utility->new($first_event->{release_date});

    #for live pricing, following condition should be satisfied
    if ( $from >= $first_event_date->epoch ) {
        my @matching_events;

        for my $event (@{$events}) {
            $event->{release_date} = Date::Utility->new($event->{release_date});
            my $epoch = $event->{release_date}->epoch;

            push @matching_events, $event if ($epoch >= $from and $epoch <= $to);
        }

        return \@matching_events;
    }

    #if the requested period lies outside the current Redis data, refer to historical data
    my $documents = BOM::System::Chronicle::get_for_period(EE, EE, $from, $to);

    #we use a hash-table to remove duplicate news
    my %all_events;

    #now combine received data with $events
    for my $doc (@{$documents}) {
        #combine $doc->{events} with current $events
        my $doc_events = $doc->{events};

        for my $doc_event (@{$doc_events}) {
            my $key = $doc_event->{event_name} . $doc_event->{impact} . $doc_event->{symbol} . $doc_event->{release_date};

            $doc_event->{release_date} = Date::Utility->new($doc_event->{release_date});
            my $epoch = $doc_event->{release_date}->epoch;

            $all_events{$key} = $doc_event if ($epoch >= $from and $epoch <= $to);
        }
    }

    my @result = values %all_events;
    return \@result;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
