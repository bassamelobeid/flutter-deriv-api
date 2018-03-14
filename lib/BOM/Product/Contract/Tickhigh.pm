package BOM::Product::Contract::Tickhigh;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::AmericanExpiry', 'BOM::Product::Role::HighLowTicks';

use List::Util qw/max any/;

use Pricing::Engine::HighLowTicks;

use BOM::Product::Pricing::Greeks::ZeroGreek;

sub check_expiry_conditions {

    my $self = shift;

    my $ticks = $self->underlying->ticks_in_between_start_limit({
        start_time => $self->date_start->epoch + 1,
        limit      => $self->ticks_to_expiry,
    });

    my $number_of_ticks = scalar(@$ticks);

    # If there's no tick yet, the contract is not expired.
    return 0 if $number_of_ticks < $self->selected_tick;

    my $selected_quote = $ticks->[$self->selected_tick - 1]->{quote};

    # selected quote is not the highest.
    if (any { $_->{quote} > $selected_quote } @$ticks) {
        $self->value(0);
        return 1;    # contract expired
    }

    # we already have the full set of ticks, but no tick is higher than selected.
    if ($number_of_ticks == $self->ticks_to_expiry) {
        $self->value($self->payout);
        return 1;
    }

    # not expired, still waiting for ticks.
    return 0;

}

sub _validate_barrier {
    return;    # override barrier validation
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
