package BOM::MarketData::EconomicEvent;
#Chornicle Economic Event

use BOM::System::Chronicle;

=head1 NAME

BOM::MarketData::EconomicEvent

=head1 DESCRIPTION

Represents an economic event in the financial market
 
     my $eco = BOM::MarketData::EconomicEvent->new({
         symbol => $symbol,
         release_date => $rd,
         impact => $impact,
         event_name => $event_name,
         source => $source, # currently just from forexfactory
         recorded_date => $rdate,
     });

=cut

use Moose;
extends 'BOM::MarketData';

use Date::Utility;

use BOM::Market::Types;

has document => (
    is         => 'rw',
    lazy_build => 1,
);

sub _build_document {
    my $self = shift;

    return $self->_document_content;
}

around _document_content => sub {
    my $orig = shift;
    my $self = shift;

    my $data = {
        %{$self->$orig},
        event_name   => $self->event_name,
        release_date => $self->release_date->datetime_iso8601,
        impact       => $self->impact,
        source       => $self->source,
    };
    $data->{eco_symbol} = $self->eco_symbol if $self->eco_symbol;

    return $data;
};

has eco_symbol => (
    is  => 'rw',
    isa => 'Maybe[Str]',
);

=head2 release_date
Date of which the economic event will take place
=cut

has release_date => (
    is       => 'ro',
    isa      => 'bom_date_object',
    coerce   => 1,
    required => 1,
);

=head2 impact
The impact of the economic event in the scale of 1-5.
5 = highest impact. 1 = lowest impact.
=cut

has impact => (
    is      => 'ro',
    isa     => 'Num',
    default => 5,
);

=head2 source
Source of economic events.
=cut

has source => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

=head2 event_name
The name of the economic announcement.
=cut

has event_name => (
    is      => 'ro',
    isa     => 'Str',
    default => 'Not Given',
);

#this is supposed to only be called during tests.
#In order to save an economic event in live system you need to call update script which
#in turn calls Fetcher::EconomicEvent
sub save {
    my $self = shift;
    my $current_set = BOM::System::Chronicle::get('economic_events', 'economic_events');

    #if this is the first event ever
    $current_set //= [];

    #current_set is an array-ref
    push $current_set, $self->document;

    BOM::System::Chronicle::set('economic_events', 'economic_events', $current_set);
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
