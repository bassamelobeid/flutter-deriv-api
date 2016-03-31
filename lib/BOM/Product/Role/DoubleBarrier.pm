package BOM::Product::Role::DoubleBarrier;

use Moose::Role;
with 'BOM::Product::Role::BarrierBuilder';

use BOM::Platform::Context qw(localize);
use BOM::Utility::ErrorStrings qw( format_error_string );

sub BUILD {
    my $self = shift;

    if (my $barrier2 = $self->low_barrier and my $barrier1 = $self->high_barrier) {
        if ($barrier2->as_absolute > $barrier1->as_absolute) {
            $self->add_error({
                severity          => 5,
                message           => 'High and low barriers inverted',
                message_to_client => localize('High barrier must be higher than low barrier.'),
            });
            $self->low_barrier($barrier1);
            $self->high_barrier($barrier2);
        } elsif ($barrier1->as_absolute == $barrier2->as_absolute) {
            $self->add_error({
                severity          => 100,
                message           => 'High and low barriers must be different',
                message_to_client => localize('High and low barriers must be different.'),
            });
            $self->low_barrier(
                $barrier1->adjust({
                        modifier => 'subtract',
                        amount   => $self->pip_size,
                        reason   => 'High and low barriers same'
                    }));
            $self->high_barrier(
                $barrier2->adjust({
                        modifier => 'add',
                        amount   => $self->pip_size,
                        reason   => 'High and low barriers same'
                    }));
        }
    }

    return;
}

has [qw(supplied_high_barrier supplied_low_barrier)] => (is => 'ro');

has [qw(high_barrier low_barrier)] => (
    is         => 'rw',
    isa        => 'Maybe[BOM::Product::Contract::Strike]',
    lazy_build => 1,
);

sub _build_high_barrier {
    my $self = shift;
    return $self->make_barrier($self->supplied_high_barrier);
}

sub _build_low_barrier {
    my $self = shift;
    return $self->make_barrier($self->supplied_low_barrier);
}

sub _barriers_for_pricing {
    my $self = shift;
    return {
        barrier1 => $self->_apply_barrier_adjustment($self->high_barrier->as_absolute),
        barrier2 => $self->_apply_barrier_adjustment($self->low_barrier->as_absolute),
    };
}

sub _barriers_for_shortcode {
    my $self = shift;
    return ($self->high_barrier and $self->low_barrier) ? ($self->high_barrier->for_shortcode, $self->low_barrier->for_shortcode) : ();
}

sub _validate_barrier {
    my $self = shift;

    my $high_barrier = $self->high_barrier;
    my $low_barrier  = $self->low_barrier;
    my $current_spot = $self->current_spot;

    my @errors;
    push @errors, $high_barrier->all_errors if not $high_barrier->confirm_validity;
    push @errors, $low_barrier->all_errors  if not $low_barrier->confirm_validity;
    if (not defined $high_barrier or not defined $low_barrier) {
        push @errors,
            {
            severity          => 100,
            message           => 'At least one barrier is undefined on double barrier contract.',
            message_to_client => localize('The barriers are improperly entered for this contract.'),
            };
    }
    if ($high_barrier->supplied_type ne $low_barrier->supplied_type) {
        push @errors,
            {
            severity          => 5,
            message           => 'Mixed absolute and relative barriers',
            message_to_client => localize('Proper barriers could not be determined.'),
            };
    }
    if ($self->is_path_dependent) {
        my $high_pip_move = $self->high_barrier->pip_difference;
        my $low_pip_move  = $self->low_barrier->pip_difference;
        my $min_allowed   = $self->minimum_allowable_move;
        if ($high_barrier->as_absolute <= $current_spot or $low_barrier->as_absolute >= $current_spot) {
            push @errors,
                {
                message => format_error_string(
                    'Barriers should straddle the spot',
                    spot => $current_spot,
                    high => $high_barrier->as_absolute,
                    low  => $low_barrier->as_absolute
                ),
                severity          => 1,
                message_to_client => localize('Barriers must be on either side of the spot.'),
                };
        } elsif (abs($high_pip_move) < $min_allowed or abs($low_pip_move) < $min_allowed) {
            push @errors,
                {
                message => format_error_string(
                    'Relative barrier path dependent move below minimum',
                    'high move' => $high_pip_move,
                    'low move'  => $low_pip_move,
                    min         => $min_allowed
                ),
                severity          => 1,
                message_to_client => localize('Barrier must be at least ' . $min_allowed . ' pips away from the spot.'),
                };
        }
    }
    my ($min_move, $max_move) = (0.25, 2.5);
    foreach my $pair (['low' => $low_barrier], ['high' => $high_barrier]) {
        my ($label, $barrier) = @$pair;
        next unless $barrier;
        my $abs_barrier = $barrier->as_absolute;
        if ($abs_barrier > $max_move * $current_spot or $abs_barrier < $min_move * $current_spot) {
            push @errors,
                {
                message => format_error_string(
                    'Barrier too far from spot',
                    move => $abs_barrier / $current_spot,
                    min  => $min_move,
                    max  => $max_move
                ),
                severity          => 91,
                message_to_client => ($label eq 'low')
                ? localize('Low barrier is out of acceptable range. Please adjust the low barrier.')
                : localize('High barrier is out of acceptable range. Please adjust the high barrier.'),
                ,
                };
        }
    }

    return @errors;
}

1;
