package BOM::Product::Role::SingleBarrier;

use Moose::Role;
use List::Util qw(first);

use BOM::Product::Static;

with 'BOM::Product::Role::BarrierBuilder';

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

has supplied_barrier => (is => 'ro');

has barrier => (
    is      => 'ro',
    isa     => 'Maybe[BOM::Product::Contract::Strike]',
    lazy    => 1,
    builder => '_build_barrier',
);

sub _build_barrier {
    my $self    = shift;
    my $barrier = $self->make_barrier($self->supplied_barrier);
    return $barrier;
}
has barriers_for_pricing => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_barriers_for_pricing',
);

sub _build_barriers_for_pricing {
    my $self = shift;

    my $barrier = $self->barrier ? $self->barrier->as_absolute : $self->current_tick->quote;

    return {
        barrier1 => $self->_apply_barrier_adjustment($barrier),
        barrier2 => undef,
    };
}

sub _validate_barrier {
    my $self = shift;

    my ($barrier, $pip_move) = $self->barrier ? ($self->barrier, $self->barrier->pip_difference) : ();
    my $current_spot = $self->current_spot;

    return ($barrier->all_errors)[0] if defined $barrier and not $barrier->confirm_validity;
    return unless $self->has_user_defined_barrier;

    my ($min_move, $max_move) = (0.25, 2.5);
    my $abs_barrier = (defined $barrier) ? $barrier->as_absolute : undef;
    if (defined $barrier and $barrier->supplied_barrier eq '0' and not $self->is_intraday) {
        return {
            message           => 'Absolute barrier cannot be zero',
            severity          => 1,
            message_to_client => [$ERROR_MAPPING->{ZeroAbsoluteBarrier}],
        };
    } elsif ($abs_barrier and $current_spot and ($abs_barrier > $max_move * $current_spot or $abs_barrier < $min_move * $current_spot)) {
        return {
            message => 'Barrier too far from spot '
                . "[move: "
                . ($abs_barrier / $current_spot) . "] "
                . "[min: "
                . $min_move . "] "
                . "[max: "
                . $max_move . "]",
            severity          => 91,
            message_to_client => [$ERROR_MAPPING->{BarrierOutOfRange}],
        };
    } elsif (not $self->for_sale and $self->is_path_dependent and abs($pip_move) < $self->minimum_allowable_move) {
        return {
            message => 'Relative barrier path dependent move below minimum '
                . "[min: "
                . $self->minimum_allowable_move . "] "
                . "[actual: "
                . $pip_move . "]",
            severity          => 1,
            message_to_client => [$ERROR_MAPPING->{InvalidBarrierForSpot}, $self->minimum_allowable_move],
        };
    }

    return;
}

1;
