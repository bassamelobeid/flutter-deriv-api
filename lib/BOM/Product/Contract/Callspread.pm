package BOM::Product::Contract::Callspread;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Spreads';

use List::Util qw(min max);

sub check_expiry_conditions {
    my $self = shift;

    my $contract_value = 0;
    if ($self->exit_tick) {
        my $value = ($self->exit_tick->quote - $self->low_barrier->as_absolute) * $self->multiplier;
        $self->value(min($self->payout, max(0, $value)));
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
