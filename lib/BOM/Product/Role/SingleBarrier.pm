package BOM::Product::Role::SingleBarrier;

use Moose::Role;
with 'BOM::Product::Role::BarrierBuilder';

use BOM::Platform::Context qw(localize);
use BOM::Utility::ErrorStrings qw( format_error_string );

has supplied_barrier => (is => 'ro');

has barrier => (
    is      => 'ro',
    isa     => 'Maybe[BOM::Product::Contract::Strike]',
    lazy    => 1,
    builder => '_build_barrier',
);

sub _build_barrier {
    my $self = shift;
    return $self->make_barrier($self->supplied_barrier);
}

sub _barriers_for_pricing {
    my $self = shift;

    my $barrier = $self->barrier ? $self->barrier->as_absolute : $self->current_tick->quote;

    return {
        barrier1 => $self->_apply_barrier_adjustment($barrier),
        barrier2 => undef,
    };
}

sub _barriers_for_shortcode {
    my $self = shift;
    return $self->barrier ? ($self->barrier->for_shortcode, 0) : ();
}

sub _validate_barrier {
    my $self = shift;

    my ($barrier, $pip_move) = $self->barrier ? ($self->barrier, $self->barrier->pip_difference) : ();
    my $current_spot = $self->current_spot;

    return ($barrier->all_errors)[0] if defined $barrier and not $barrier->confirm_validity;

    my ($min_move, $max_move) = (0.25, 2.5);
    my $abs_barrier = (defined $barrier) ? $barrier->as_absolute : undef;
    if ($abs_barrier and $current_spot and ($abs_barrier > $max_move * $current_spot or $abs_barrier < $min_move * $current_spot)) {
        return {
            message => format_error_string(
                'Barrier too far from spot',
                move => $abs_barrier / $current_spot,
                min  => $min_move,
                max  => $max_move,
            ),
            severity          => 91,
            message_to_client => localize('Barrier is out of acceptable range.'),
            };
    } elsif ($self->is_path_dependent and abs($pip_move) < $self->minimum_allowable_move) {
        return {
            message => format_error_string(
                'Relative barrier path dependent move below minimum',
                min    => $self->minimum_allowable_move,
                actual => $pip_move
            ),
            severity          => 1,
            message_to_client => localize('Barrier must be at least ' . $self->minimum_allowable_move . ' pips away from the spot.'),
            };
    }

    return;
}

1;
