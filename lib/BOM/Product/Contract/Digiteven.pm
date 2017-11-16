package BOM::Product::Contract::Digiteven;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use Pricing::Engine::Digits;

use BOM::Product::Contract::Strike::Digit;
use BOM::Product::Pricing::Greeks::Digits;

sub ticks_to_expiry {
    return shift->tick_count;
}

sub _build_pricing_engine_name {
    return 'Pricing::Engine::Digits';
}

sub _build_greek_engine {
    return BOM::Product::Pricing::Greeks::Digits->new({bet => shift});
}

sub _build_barrier {
    # We don't use this barrier for settlement. But it is needed because of database constraint.
    # Setting it to zero.
    return BOM::Product::Contract::Strike::Digit->new(supplied_barrier => 0);
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my $last_digit = (split //, $self->underlying->pipsized_value($self->exit_tick->quote))[-1];
        my $value = ($last_digit % 2 == 0) ? $self->payout : 0;
        $self->value($value);
    }

    return;
}

sub _validate_barrier {
    return;    # override barrier validation
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
