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

    for (EE, EET) {
        $self->chronicle_writer->set(EE, $_, {}) unless defined $self->chronicle_reader->get(EE, $_);
    }

    #receive tentative events hash
    my $existing_tentatives = $self->get_tentative_events;

    for my $event (@{$self->events}) {
        if ($event->{id} && $existing_tentatives->{$event->{id}}) {
            # We need to do this because we need a full transition record
            # of a tentative event in both EE and EET tables
            $existing_tentatives->{$event->{id}} = $event = {(%{$existing_tentatives->{$event->{id}}}, %$event)};
        } elsif ($event->{is_tentative}) {
            $existing_tentatives->{$event->{id}} = $event;
        }
    }

    #delete tentative events in EET one month after its release date.
    foreach my $id (keys %$existing_tentatives) {
        delete $existing_tentatives->{$id} if time > $existing_tentatives->{$id}->{release_date} + 30 * 86400;
    }

    return (
        $self->chronicle_writer->set(EE, EET, $existing_tentatives,     $self->recorded_date),
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

    #for live pricing, following condition should be satisfied
    #release date is now an epoch and not a date string.
    if ($from >= $events->[0]->{release_date}) {
        return [grep {$_->{release_date} >= $from and $_->{release_date} <= $to} @$events];
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
