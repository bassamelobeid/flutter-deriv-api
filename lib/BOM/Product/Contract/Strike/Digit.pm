package BOM::Product::Contract::Strike::Digit;

use Moose;
use namespace::autoclean;

extends 'BOM::Product::Contract::Strike';

use Carp qw( croak );

has '+basis_tick' => (
    required => 0,
);

sub BUILD {
    my $self = shift;

    croak(__PACKAGE__ . ' can only accept supplied_barriers of 1 digit: [' . $self->supplied_barrier . ']')
        unless (defined $self->supplied_barrier
        && $self->supplied_barrier =~ /^[0-9]$/);

    return;
}

override _build_supplied_type => sub {
    return 'digit';
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
