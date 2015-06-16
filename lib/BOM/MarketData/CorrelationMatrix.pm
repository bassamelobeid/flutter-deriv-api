package BOM::MarketData::CorrelationMatrix;

=head1 NAME

BOM::MarketData::CorrelationMatrix;

=head1 DESCRIPTION

Correlations have an index, a currency, and duration that corresponds
to a correlation. An example of a correlation is SPC, AUD, 1M, with
a correlation of 0.42.

=cut

use Moose;
extends 'BOM::MarketData';

use namespace::autoclean;
use Data::Compare qw( Compare );
use Math::Function::Interpolator;
use BOM::Market::Underlying;
use Date::Utility;

has _data_location => (
    is      => 'ro',
    default => 'correlation_matrices',
);

around _document_content => sub {
    my $orig = shift;
    my $self = shift;

    return {
        # symbol is not required
        date         => $self->recorded_date->datetime_iso8601,
        correlations => $self->correlations,
    };
};

with 'BOM::MarketData::Role::VersionedSymbolData';

has correlations => (
    is         => 'rw',
    isa        => 'HashRef',
    lazy_build => 1,
);

has _latest_correlations_reload => (
    is      => 'rw',
    isa     => 'Int',
    default => sub { time },
);

has reload_frequency => (
    is      => 'ro',
    isa     => 'Int',
    default => 20,
);

=head2 recorded_date

The date (and time) that the correlation matrix  was recorded, as a Date::Utility.

=cut

has recorded_date => (
    is         => 'ro',
    isa        => 'Date::Utility',
    lazy_build => 1,
);

sub _build_recorded_date {
    my $self = shift;
    return Date::Utility->new($self->document->{date});
}

# Instances of this class are able to auto-reload themselves to ensure
# that long-lived objects keep themselves up to date with change to the
# underlying CouchDB document.
#
# This auto-reloading only occurs when the document is the
# live_document however, as if it is not, the instance is essentially
# representing a historical correlation matrix, which will never change.
#
# The correlations attr is a copy of the data->correlations HashRef as
# stored on the document. We reload the correlations attr if
# it has not changed from the original document value. If it
# has, we assume the user wishes to update the matrix, so we do not
# update (i.e. clear) the attr.
#
# We also assume that the user of the object will retrieve correlation
# data via the correlation attr.
before correlations => sub {
    my $self = shift;

    if ($self->_latest_correlations_reload + $self->reload_frequency < time) {
        $self->clear_correlations;
        $self->_latest_correlations_reload(time);
    }
};

sub _build_correlations {
    my $self = shift;

    return $self->document->{correlations};
}

sub correlation_for {
    my ($self, $index, $payout_currency, $tiy) = @_;

    # For synthetic, it will use the mapped underlying correlation
    if ($index =~ /^SYN(\w+)/) {
        $index = $1;
    }
    my $sought_expiry = $tiy * 365.0;
    my $data_points   = $self->correlations->{$index}->{$payout_currency};
    my $underlying    = BOM::Market::Underlying->new($index);
    my $mapped_data;

    foreach my $tenor (keys %{$data_points}) {
        my $day = $underlying->vol_expiry_date({
                from => $self->recorded_date,
                term => $tenor,
            })->days_between($self->recorded_date);

        $mapped_data->{$day} = $data_points->{$tenor};
    }

    return ($sought_expiry) ? Math::Function::Interpolator->new(points => $mapped_data)->linear($sought_expiry) : 0;
}

around BUILDARGS => sub {
    my $orig  = shift;
    my $class = shift;

    my @args = (scalar @_ == 1 and not ref $_[0]) ? {symbol => $_[0]} : @_;

    return $class->$orig(@args);
};

__PACKAGE__->meta->make_immutable;
1;
