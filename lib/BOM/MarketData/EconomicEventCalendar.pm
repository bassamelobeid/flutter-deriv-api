package BOM::MarketData::EconomicEventCalendar;
#Chornicle Economic Event

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
use Digest::MD5 qw(md5_hex);

extends 'BOM::MarketData';

use Date::Utility;

use BOM::Market::Types;

use constant EE  => 'economic_events';
use constant EET => 'economic_events_tentative';

has document => (
    is         => 'rw',
    lazy_build => 1,
);

has chronicle_reader => (
    is      => 'ro',
    isa     => 'Data::Chronicle::Reader',
    default => sub { BOM::System::Chronicle::get_chronicle_reader() },
);

has chronicle_writer => (
    is      => 'ro',
    isa     => 'Data::Chronicle::Writer',
    default => sub { BOM::System::Chronicle::get_chronicle_writer() },
);

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

has events => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_events {
    my $self = shift;
    return $self->document->{events};
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

    if (not defined $self->chronicle_reader->get(EE, EE)) {
        $self->chronicle_writer->set(EE, EE, {});
    }

    if (not defined $self->get_tentative_events) {
        $self->chronicle_writer->set(EE, EET, {});
    }

    #receive tentative events hash
    my $tentative_events = $self->get_tentative_events;

    for my $event (@{$self->events}) {
        if (ref($event->{release_date}) eq 'Date::Utility') {
            $event->{release_date} = $event->{release_date}->datetime_iso8601;
        }

        #update event if it's tentative
        if ($event->{id} && $tentative_events->{$event->{id}}) {
            my $is_tentative = $event->{is_tentative};
            $tentative_events->{$event->{id}} = $event = {(%{$tentative_events->{$event->{id}}}, %$event)};
        } elsif ($event->{is_tentative}) {
            $tentative_events->{$event->{id}} = $event;
        }
    }

    # delete tentative event from tentative table after one month it happened
    foreach my $id (keys %$tentative_events) {
        if ($tentative_events->{$id}->{release_date} && $tentative_events->{$id}->{release_date} < time - 60 * 60 * 24 * 31) {
            delete $tentative_events->{$id};
        }
    }

    return (
        $self->chronicle_writer->set(EE, EET, $tentative_events,        $self->recorded_date),
        $self->chronicle_writer->set(EE, EE,  $self->_document_content, $self->recorded_date));
}

sub update {

    my $self             = shift;
    my $events           = $self->chronicle_reader->get(EE, EE);
    my $tentative_events = $self->get_tentative_events;

    if ($events and ref($events->{events}) eq 'ARRAY' and $tentative_events) {

        my %new_events_hash = map { $_->{id} => $_ } @{$self->{events}};

        for my $event (@{$events->{events}}) {
            if (defined $new_events_hash{$event->{id}}) {
                $event = {(%$event, %{$new_events_hash{$event->{id}}})};
            }
        }

        foreach my $id (keys %$tentative_events) {
            if (defined($new_events_hash{$id})) {
                $tentative_events->{$id} = {(%{$tentative_events->{$id}}, %{$new_events_hash{$id}})};
            }
            # delete tentative event from tentative table after one month it happened
            if ($tentative_events->{$id}->{release_date} && $tentative_events->{$id}->{release_date} < time - 60 * 60 * 24 * 31) {
                delete $tentative_events->{$id};
            }
        }
    }

    return (
        $self->chronicle_writer->set(EE, EET, $tentative_events, $self->recorded_date),
        $self->chronicle_writer->set(EE, EE,  $events,           $self->recorded_date));
}

sub get_latest_events_for_period {
    my ($self, $period) = @_;

    my $from = Date::Utility->new($period->{from})->epoch;
    my $to   = Date::Utility->new($period->{to})->epoch;

    #get latest events
    my $document = $self->chronicle_reader->get(EE, EE);

    die "No economic events" if not defined $document;

    #extract first event from current document to check whether we need to get back to historical data
    my $events           = $document->{events};
    my $first_event      = $events->[0];
    my $first_event_date = Date::Utility->new($first_event->{release_date});

    #for live pricing, following condition should be satisfied
    if ($from >= $first_event_date->epoch) {
        my @matching_events;

        for my $event (@{$events}) {
            $event->{release_date} = Date::Utility->new($event->{release_date});
            my $epoch = $event->{release_date}->epoch;

            push @matching_events, $event if ($epoch >= $from and $epoch <= $to);
        }

        return \@matching_events;
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

            $doc_event->{release_date} = Date::Utility->new($doc_event->{release_date});
            my $epoch = $doc_event->{release_date}->epoch;

            $doc_event->{id} = substr(
                md5_hex(
                    $doc_event->{release_date}->truncate_to_day()->epoch . $doc_event->{event_name} . $doc_event->{symbol} . $doc_event->{impact}
                ),
                0, 16
            ) unless defined $doc_event->{id};

            $all_events{$doc_event->{id}} = $doc_event if ($epoch >= $from and $epoch <= $to);
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
