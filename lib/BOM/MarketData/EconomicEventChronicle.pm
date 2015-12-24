package BOM::MarketData::EconomicEventChronicle;

=head1 NAME

BOM::MarketData::EconomicEvent

=head1 DESCRIPTION

This is a temporary module to hold what will be finally stored in EconomicEvent of MarketData.
We will use this module to write economic events data to Chronicle.

=cut

use Moose;
extends 'BOM::MarketData';

use Date::Utility;

use BOM::Market::Types;
use BOM::MarketData::Fetcher::EconomicEvent;

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

no Moose;
__PACKAGE__->meta->make_immutable;
1;
