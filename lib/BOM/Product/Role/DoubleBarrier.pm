package BOM::Product::Role::DoubleBarrier;

use Moose::Role;
with 'BOM::Product::Role::BarrierBuilder';

use List::Util qw(first);
use BOM::Platform::Context qw(localize);

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

has [qw(original_high_barrier original_low_barrier)] => (
    is  => 'rw',
    isa => 'Maybe[BOM::Product::Contract::Strike]'
);

has high_barrier => (
    is      => 'rw',
    isa     => 'Maybe[BOM::Product::Contract::Strike]',
    lazy    => 1,
    builder => '_build_high_barrier',
);

sub _build_high_barrier {
    my $self = shift;

    my $high_barrier = $self->make_barrier($self->supplied_high_barrier);
    $self->original_high_barrier($self->initial_barrier) if defined $self->initial_barrier;
    return $high_barrier;
}

has low_barrier => (
    is      => 'rw',
    isa     => 'Maybe[BOM::Product::Contract::Strike]',
    lazy    => 1,
    builder => '_build_low_barrier',
);

sub _build_low_barrier {
    my $self = shift;

    my $low_barrier = $self->make_barrier($self->supplied_low_barrier);
    $self->original_low_barrier($self->initial_barrier) if defined $self->initial_barrier;
    return $low_barrier;
}
has barriers_for_pricing => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_barriers_for_pricing',
);

sub _build_barriers_for_pricing {
    my $self = shift;
    return {
        barrier1 => $self->_apply_barrier_adjustment($self->high_barrier->as_absolute),
        barrier2 => $self->_apply_barrier_adjustment($self->low_barrier->as_absolute),
    };
}

sub _validate_barrier {
    my $self = shift;

    my $high_barrier = $self->high_barrier;
    my $low_barrier  = $self->low_barrier;
    my $current_spot = $self->current_spot;

    return ($high_barrier->all_errors)[0] if not $high_barrier->confirm_validity;
    return ($low_barrier->all_errors)[0]  if not $low_barrier->confirm_validity;
    if (not defined $high_barrier or not defined $low_barrier) {
        return {
            severity          => 100,
            message           => 'At least one barrier is undefined on double barrier contract.',
            message_to_client => localize('The barriers are improperly entered for this contract.'),
        };
    }
    if ($high_barrier->supplied_type ne $low_barrier->supplied_type) {
        return {
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
            return {
                message => 'Barriers should straddle the spot '
                    . "[spot: "
                    . $current_spot . "] "
                    . "[high: "
                    . $high_barrier->as_absolute . "] "
                    . "[low: "
                    . $low_barrier->as_absolute . "]",
                severity          => 1,
                message_to_client => localize('Barriers must be on either side of the spot.'),
            };
        } elsif (abs($high_pip_move) < $min_allowed or abs($low_pip_move) < $min_allowed) {
            return {
                message => 'Relative barrier path dependent move below minimum '
                    . "[high move: "
                    . $high_pip_move . "] "
                    . "[low move: "
                    . $low_pip_move . "] "
                    . "[min: "
                    . $min_allowed . "]",
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
            return {
                message => 'Barrier too far from spot '
                    . "[move: "
                    . ($abs_barrier / $current_spot) . "] "
                    . "[min: "
                    . $min_move . "] "
                    . "[max: "
                    . $max_move . "]",
                severity          => 91,
                message_to_client => ($label eq 'low')
                ? localize('Low barrier is out of acceptable range. Please adjust the low barrier.')
                : localize('High barrier is out of acceptable range. Please adjust the high barrier.'),
                ,
            };
        }
    }

    if (%{$self->predefined_contracts} and my $info = $self->predefined_contracts->{$self->date_expiry->epoch}) {
        my @available_barriers = @{$info->{available_barriers} // []};
        my @expired_barriers   = @{$info->{expired_barriers}   // []};

        my @filtered;
        foreach my $pair (@available_barriers) {
            # checks for expired barriers and exclude them from available barriers.
            my $barrier_expired = first { $pair->[0] eq $_->[0] and $pair->[1] eq $_->[1] } @expired_barriers;
            next if $barrier_expired;
            push @filtered, $pair;
        }

        if (
            not(@filtered
                and first { $low_barrier->as_absolute eq $_->[0] and $high_barrier->as_absolute eq $_->[1] } @filtered))
        {
            return {
                message => 'Invalid barriers['
                    . $low_barrier->as_absolute . ','
                    . $high_barrier->as_absolute
                    . '] for expiry ['
                    . $self->date_expiry->datetime
                    . '] and contract type['
                    . $self->code
                    . '] for japan at '
                    . $self->date_pricing->datetime . '.',
                message_to_client => localize('Invalid barrier.'),
            };
        }
    }

    return;
}

1;
