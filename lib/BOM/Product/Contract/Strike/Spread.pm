package BOM::Product::Contract::Strike::Spread;

use Moose;
use namespace::autoclean;
extends 'BOM::Product::Contract::Strike';

use Carp qw( croak );

has '+basis_tick' => (
    required => 0,
);

sub BUILD {
    my $self = shift;

    croak(__PACKAGE__ . ' can only accept absolute barrier as supplied barrier: [' . $self->supplied_barrier . ']')
        unless (defined $self->supplied_barrier
        && $self->supplied_barrier =~ /^(\d+)\.?(\d+)?$/);

    return;
}

override _build_supplied_type => sub {
    return 'spread';
};

override _build_as_relative => sub {
    my $self = shift;

    return $self->supplied_barrier;
};

override _build_as_absolute => sub {
    my $self = shift;

    return $self->supplied_barrier;
};

override _build_as_difference => sub {
    my $self = shift;

    return $self->supplied_barrier;
};

override _build_pip_difference => sub {
    my $self = shift;

    return $self->supplied_barrier;
};

override for_shortcode => sub {
    my $self = shift;

    return $self->supplied_barrier;
};

override display_text => sub {
    my $self = shift;

    return $self->supplied_barrier;
};


__PACKAGE__->meta->make_immutable;
1;
