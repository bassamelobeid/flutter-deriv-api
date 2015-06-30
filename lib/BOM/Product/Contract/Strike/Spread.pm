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
    return 'digit';
};

override [qw(_build_as_relative _build_as_absolute _build_as_difference _build_as_pip_difference for_short_code display_text)] => sub {
    my $self = shift;
    return $self->supplied_barrier;
};

__PACKAGE__->meta->make_immutable;
1;
