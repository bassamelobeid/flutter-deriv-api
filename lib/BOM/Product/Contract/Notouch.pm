package BOM::Product::Contract::Notouch;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::AmericanExpiry';

sub ticks_to_expiry {
# Add one since we want N ticks *after* the entry spot
    return shift->tick_count + 1;
}

sub check_expiry_conditions {
    my $self = shift;

    my $value = $self->hit_tick ? 0 : $self->payout;
    $self->value($value);

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
