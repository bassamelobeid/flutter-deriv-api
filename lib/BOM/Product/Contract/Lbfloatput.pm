package BOM::Product::Contract::Lbfloatput;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Lookback', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub code { return 'LBFLOATPUT'; }

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my ($high) = @{$self->get_ohlc_for_period()}{qw(high)};
        if (defined $high) {
            my $value = $high - $self->exit_tick->quote;
            $self->value($value);
        }
    }

    return;
}

sub _build_barrier {
    my $self = shift;

    my $barrier;
    $barrier = $self->make_barrier($self->spot_max);

    return $barrier;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

