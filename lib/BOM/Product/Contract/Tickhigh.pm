package BOM::Product::Contract::Tickhigh;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::AmericanExpiry', 'BOM::Product::Role::HighLowTicks';

use List::Util qw/any/;

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
    return 0 unless $self->barrier;

    my $selected_quote = $self->barrier->as_absolute;

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

# Returns a hash of permitted inputs
sub get_permissible_inputs {
    return {
        # Contract-relevant inputs
        'bet_type'      => 1,
        'underlying'    => 1,
        'amount_type'   => 1,
        'amount'        => 1,
        'date_start'    => 1,
        'selected_tick' => 1,
        'date_expiry'   => 1,
        'currency'      => 1,

        # Metadata inputs
        'shortcode'    => 1,
        'fixed_expiry' => 1,
        'tick_expiry'  => 1,
        'tick_count'   => 1,
        'is_sold'      => 1,
    };
}

sub _validate_barrier {
    return undef;    # override barrier validation
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
