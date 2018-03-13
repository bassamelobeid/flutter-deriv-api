package BOM::Product::Contract::Lbfloatput;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Lookback', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my $value = ($self->barrier->as_absolute - $self->exit_tick->quote) * $self->multiplier;
        $self->value($value);
    }

    return;
}

sub _build_barrier {
    my $self = shift;

    return $self->make_barrier($self->spot_min_max->{high});
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

