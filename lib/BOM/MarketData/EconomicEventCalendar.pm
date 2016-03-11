package BOM::MarketData::EconomicEventCalendar;
#Chornicle Economic Event

use Carp qw(croak);
use BOM::System::Chronicle;
use Data::Chronicle::Reader;
use Data::Chronicle::Writer;

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
use JSON;
use ForexFactory;

extends 'BOM::MarketData';

use Date::Utility;
use List::MoreUtils qw(firstidx);
use BOM::Market::Types;

use constant EE  => 'economic_events';
use constant EET => 'economic_events_tentative';

has document => (
    is         => 'rw',
    lazy_build => 1,
);

sub chronicle_reader {
    return BOM::System::Chronicle::get_chronicle_reader();
}

sub chronicle_writer {
    return BOM::System::Chronicle::get_chronicle_writer();
)

#this sub needs to be removed as it is no loger used.
#we use `get_latest_events_for_period` to read economic events.
sub _build_document {
    my $self = shift;

    #document is an array of hash
    #each hash represents a single economic event
    return $self->chronicle_reader->get(EE, EE);
}

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

=head2 events

Array reference of Economic events. Potentially contains tentative events.

=cut

has events => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_events {
    my $self = shift;
    return $self->document->{events};
}

# economic events to be recorded to chronicle after processing.
# tentative events without release_date will not be including in this list.
has _events => (
    is => 'rw',
);

around _document_content => sub {
    my $orig = shift;
    my $self = shift;

    #this will contain symbol, date and events
    my $data = {
        %{$self->$orig},
        events => $self->_events,
    };

    return $data;
};

=head3 C<< save >>

Saves the calendar into Chronicle

=cut

sub save {
    my $self = shift;

    for (EE, EET) {
        $self->chronicle_writer->set(EE, $_, {}) unless defined $self->chronicle_reader->get(EE, $_);
    }
    #receive tentative events hash
    my $existing_tentatives = $self->get_tentative_events;

    foreach my $event (@{$self->events}) {
        my $id = $event->{id};
        next unless $id;
        # update existing tentative events
        if (my $ete = $existing_tentatives->{$id}) {
            if (not $event->{is_tentative}) {
                $event->{actual_release_date} = $event->{release_date} if $event->{release_date};
            } else {
                for my $key (grep { $ete->{$_} } qw(blankout blankout_end estimated_release_date release_date)) {
                    $event->{$key} = $ete->{$key};
                }
            }
        } elsif ($event->{is_tentative}) {
            $existing_tentatives->{$id} = $event;
        }
    }

    #delete tentative events in EET one month after its estimated release date.
    foreach my $id (keys %$existing_tentatives) {
        delete $existing_tentatives->{$id} if time > $existing_tentatives->{$id}->{estimated_release_date} + 30 * 86400;
    }

    # We are only interest in events with a release_date so that we can actually act on it
    # when we price contracts. $self->events could potentially contain:
    # 1) regular scheduled events
    # 2) tentative events that we do not care. (those that we don't add blockout times for them, we treat it as if they don't exist)
    # 3) tentative events that we care. (with blockout time and release_date)
    my @regular_events =
        sort { $a->{release_date} <=> $b->{release_date} } grep { $_->{release_date} } @{$self->events};
    $self->_events(\@regular_events);

    return (
        $self->chronicle_writer->set(EE, EET, $existing_tentatives,     $self->recorded_date),
        $self->chronicle_writer->set(EE, EE,  $self->_document_content, $self->recorded_date));
}

sub update {
    my ($self, $params) = @_;

    my $existing_events = $self->chronicle_reader->get(EE, EE) || {};
    my $tentative_events = $self->get_tentative_events || {};

    croak "Specify a blackout start and end to update tentative event" unless ($params->{blankout} and $params->{blankout_end});
    croak "could not find $params->{id} in tentative table" unless $tentative_events->{$params->{id}};

    $params->{release_date} = int(($params->{blankout} + $params->{blankout_end}) / 2);
    $existing_events->{events} = [] unless $existing_events->{events};
    my $index = firstidx { $params->{id} eq $_->{id} } @{$existing_events->{events}};
    if ($index != -1) {
        $existing_events->{events}->[$index] = $params;
    } else {
        push @{$existing_events->{events}}, $params;
    }

    $tentative_events->{$params->{id}} = {(%{$tentative_events->{$params->{id}}}, %$params)};

    return (
        $self->chronicle_writer->set(EE, EET, $tentative_events, $self->recorded_date),
        $self->chronicle_writer->set(EE, EE,  $existing_events,  $self->recorded_date));
}

sub get_latest_events_for_period {
    my ($self, $period) = @_;

    my $from = Date::Utility->new($period->{from})->epoch;
    my $to   = Date::Utility->new($period->{to})->epoch;

    #get latest events
    my $document = $self->chronicle_reader->get(EE, EE);

    die "No economic events" if not defined $document;

    #extract first event from current document to check whether we need to get back to historical data
    my $events = $document->{events};

    #for live pricing, following condition should be satisfied
    #release date is now an epoch and not a date string.
    if (@$events and $from >= $events->[0]->{release_date}) {
        return [grep { $_->{release_date} >= $from and $_->{release_date} <= $to } @$events];
    }

    #if the requested period lies outside the current Redis data, refer to historical data
    my $documents = $self->chronicle_reader->get_for_period(EE, EE, $from, $to);

    #we use a hash-table to remove duplicate news
    my %all_events;

    #now combine received data with $events
    for my $doc (@{$documents}) {
        #combine $doc->{events} with current $events
        my $doc_events = $doc->{events};
        for my $doc_event (@{$doc_events}) {
            $doc_event->{id} =
                ForexFactory::generate_id(Date::Utility->new($doc_event->{release_date})->truncate_to_day()->epoch
                    . $doc_event->{event_name}
                    . $doc_event->{symbol}
                    . $doc_event->{impact})
                unless defined $doc_event->{id};

            $all_events{$doc_event->{id}} = $doc_event if ($doc_event->{release_date} >= $from and $doc_event->{release_date} <= $to);
        }
    }

    my @result = values %all_events;
    return \@result;
}

sub get_tentative_events {

    my $self = shift;
    return $self->chronicle_reader->get(EE, EET);
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
