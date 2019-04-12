package BOM::Product::Contract::Ticklow;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier',
    'BOM::Product::Role::AmericanExpiry' => {-excludes => ['_build_hit_tick']},
    'BOM::Product::Role::HighLowTicks';

use Pricing::Engine::HighLowTicks;

use BOM::Product::Pricing::Greeks::ZeroGreek;

sub check_expiry_conditions {
    my $self = shift;

    my $value = $self->hit_tick ? 0 : $self->payout;
    $self->value($value);

    return;
}

sub _build_hit_tick {
    my $self = shift;

    return 0 unless $self->barrier;

    my $selected_quote = $self->barrier->as_absolute;
    my $ticks          = $self->_all_ticks;

    my $hit_tick;
    # Returns the first tick that is higher than barrier.
    foreach my $tick (@$ticks) {
        if ($tick->{quote} < $selected_quote) {
            $hit_tick = $tick;
            last;
        }
    }

    return $hit_tick;
}

has lowest_tick => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_lowest_tick {
    my $self = shift;

    my $ticks = $self->_all_ticks;

    # if we don't have all the ticks, we can't decide which is the lowest
    return if scalar(@$ticks) != $self->ticks_to_expiry;

    my $lowest;
    foreach my $tick (@$ticks) {
        unless ($lowest) {
            $lowest = $tick;
            next;
        }

        $lowest = $tick if (defined $tick->{quote} and $tick->{quote} < $lowest->{quote});
    }

    return $lowest;
}

sub _validate_barrier {
    return;    # override barrier validation
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
