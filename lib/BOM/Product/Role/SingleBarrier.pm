package BOM::Product::Role::SingleBarrier;

use Moose::Role;
with 'BOM::Product::Role::BarrierBuilder';

use BOM::Platform::Context qw(localize);

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
    my @errors;

    push @errors, $barrier->all_errors if defined $barrier and not $barrier->confirm_validity;
    if ($barrier and $current_spot and ($barrier->as_absolute > 2.5 * $current_spot or $barrier->as_absolute < 0.25 * $current_spot)) {
        push @errors,
            {
            message           => 'Barrier is outside of range of 25% to 250% of spot',
            severity          => 91,
            message_to_client => localize('Barrier is out of acceptable range.'),
            };
    } elsif ($self->is_path_dependent and abs($pip_move) < $self->minimum_allowable_move) {
        push @errors,
            {
            message           => 'Relative barrier path dependents must move a minimum of ' . $self->minimum_allowable_move . "pips moved[$pip_move]",
            severity          => 1,
            message_to_client => localize('Barrier must be at least ' . $self->minimum_allowable_move . ' pips away from the spot.'),
            };
    }

    return @errors;
}

1;
