package BOM::Product::Contract::Ticklow;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use List::Util qw/any min/;
use List::MoreUtils qw/indexes/;

use Pricing::Engine::HighLowTicks;

use BOM::Product::Contract::Strike::Digit;
use BOM::Product::Pricing::Greeks::Digits;

has 'selected_tick' => (
    is       => 'ro',
    required => 1,
);

sub ticks_to_expiry {
    return 5;
}

sub _build_pricing_engine_name {
    return 'Pricing::Engine::HighLowTicks';
}

sub _build_greek_engine {
    return BOM::Product::Pricing::Greeks::Digits->new({bet => shift});
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my $ticks = $self->underlying->ticks_in_between_start_limit({
            start_time => $self->date_start,
            limit      => 5
        });

        # Obtain the min value of all ticks
        my $max = min(map { $_->{quote} } @$ticks);

        # Obtain indexes where the tick is a minimum value
        my @indexes = indexes { $_->{quote} == $max } @$ticks;

        # Check if the selected tick index is the lowest tick
        my $contract_value = (any { $self->selected_tick == $_ + 1 } @indexes) ? $self->payout : 0;

        $self->value($contract_value);
    }

    return undef;
}

sub _validate_barrier {
    return;    # override barrier validation
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
