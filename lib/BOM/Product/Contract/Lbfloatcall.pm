package BOM::Product::Contract::Lbfloatcall;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Lookback', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my ($low) = @{$self->get_ohlc_for_period()}{qw(low)};
        if (defined $low) {
            my $value = ($self->exit_tick->quote - $low) * $self->multiplier;
            $self->value($value);
        }
    }

    return;
}

sub _build_barrier {
    my $self = shift;

    my $barrier;
    $barrier = $self->make_barrier($self->spot_min);

    return $barrier;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
