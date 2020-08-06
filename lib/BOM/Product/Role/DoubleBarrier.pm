package BOM::Product::Role::DoubleBarrier;

use Moose::Role;
use List::Util qw(first);
with 'BOM::Product::Role::BarrierBuilder';

use BOM::Product::Static;

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

sub BUILD {
    my $self = shift;

    return unless $self->pricing_new;

    if (my $barrier2 = $self->low_barrier and my $barrier1 = $self->high_barrier) {
        if ($barrier2->as_absolute > $barrier1->as_absolute) {
            $self->_add_error({
                severity          => 5,
                message           => 'High and low barriers inverted',
                message_to_client => [$ERROR_MAPPING->{InvalidHighBarrier}],
                details           => {field => 'barrier'},
            });
            $self->low_barrier($barrier1);
            $self->high_barrier($barrier2);
        } elsif ($self->has_user_defined_barrier
            and $barrier1->as_absolute == $barrier2->as_absolute
            and $barrier1->has_valid_decimals
            and $barrier2->has_valid_decimals)
        {
            $self->_add_error({
                severity          => 100,
                message           => 'High and low barriers must be different',
                message_to_client => [$ERROR_MAPPING->{SameBarriersNotAllowed}],
                details           => {field => 'barrier'},
            });
        }
    }

    return;
}

has [qw(supplied_high_barrier supplied_low_barrier)] => (is => 'ro');

has high_barrier => (
    is      => 'rw',
    isa     => 'Maybe[BOM::Product::Contract::Strike]',
    lazy    => 1,
    builder => '_build_high_barrier',
);

sub _build_high_barrier {
    my $self = shift;

    my $high_barrier = $self->make_barrier($self->supplied_high_barrier, {barrier_kind => 'high'});
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

    my $low_barrier = $self->make_barrier($self->supplied_low_barrier, {barrier_kind => 'low'});
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
            message_to_client => [$ERROR_MAPPING->{InvalidBarrier}],
            details           => {field => defined $high_barrier ? 'barrier2' : 'barrier'},
        };
    }
    if ($high_barrier->supplied_type ne $low_barrier->supplied_type) {
        return {
            severity          => 5,
            message           => 'Mixed absolute and relative barriers',
            message_to_client => [$ERROR_MAPPING->{NonDeterminedBarriers}],
            details           => {field => 'barrier2'},
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
                message_to_client => [$ERROR_MAPPING->{InvalidBarrierRange}],
                details           => {field => $high_barrier->as_absolute <= $current_spot ? 'barrier' : 'barrier2'},
            };
        } elsif (not $self->for_sale and (abs($high_pip_move) < $min_allowed or abs($low_pip_move) < $min_allowed)) {
            return {
                message => 'Relative barrier path dependent move below minimum '
                    . "[high move: "
                    . $high_pip_move . "] "
                    . "[low move: "
                    . $low_pip_move . "] "
                    . "[min: "
                    . $min_allowed . "]",
                severity          => 1,
                message_to_client => [$ERROR_MAPPING->{InvalidBarrierForSpot}, $min_allowed],
                details           => {field => abs($high_pip_move) < $min_allowed ? 'barrier' : 'barrier2'},
            };
        }
    }

    my ($min_move, $max_move) = (0.25, 2.5);
    my ($min_allowed_barrier, $max_allowed_barrier) = ($min_move * $current_spot, $max_move * $current_spot);
    if ($self->category_code eq 'callputspread' and $self->underlying->market->name eq 'forex') {
        my $max_allowed_pips = 400;
        $min_allowed_barrier = $current_spot - $max_allowed_pips * $self->underlying->pip_size;
        $max_allowed_barrier = $current_spot + $max_allowed_pips * $self->underlying->pip_size;
    }

    foreach my $pair (['low' => $low_barrier], ['high' => $high_barrier]) {
        my ($label, $barrier) = @$pair;
        next unless $barrier;
        my $abs_barrier = $barrier->as_absolute;
        if ($abs_barrier > $max_allowed_barrier or $abs_barrier < $min_allowed_barrier) {
            return {
                message => 'Barrier too far from spot '
                    . "[current "
                    . $label
                    . " barrier : "
                    . $abs_barrier . "] "
                    . "[min allowed barrier : "
                    . $min_allowed_barrier . "] "
                    . "[max_allowed_barrier: "
                    . $max_allowed_barrier . "]",
                severity          => 91,
                message_to_client => ($label eq 'low')
                ? [$ERROR_MAPPING->{InvalidLowBarrierRange}]
                : [$ERROR_MAPPING->{InvalidHighLowBarrierRange}],
                details => {field => ($label eq 'low') ? 'barrier2' : 'barrier'},
            };
        }
        if (not $barrier->has_valid_decimals) {
            return {
                severity          => 100,
                message           => ucfirst($label) . ' barrier decimal error',
                message_to_client => [$ERROR_MAPPING->{IncorrectBarrierOffsetDecimals}, ucfirst($label), $self->underlying->display_decimals],
                details => {field => 'barrier'},
            };
        }
    }

    if ($self->category_code eq 'callputspread' and $current_spot) {
        my $low_barrier_diff  = $self->underlying->pipsized_value(abs($low_barrier->as_absolute - $current_spot));
        my $high_barrier_diff = $self->underlying->pipsized_value(abs($high_barrier->as_absolute - $current_spot));

        $self->_add_error({
                severity          => 5,
                message           => 'High and low barriers is not symmetrical',
                message_to_client => [$ERROR_MAPPING->{SymmetricBarrier}],
                details           => {field => 'barrier'},
            }) if $low_barrier_diff != $high_barrier_diff;
    }

    return;
}
1;
