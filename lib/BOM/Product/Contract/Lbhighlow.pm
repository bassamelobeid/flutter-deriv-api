package BOM::Product::Contract::Lbhighlow;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Lookback', 'BOM::Product::Role::DoubleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub code { return 'LBHIGHLOW'; }

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my ($high, $low) = @{$self->get_ohlc_for_period()}{qw(high low)};
        if (defined $high and defined $low) {
            my $value = $high - $low;
            $self->value($value);
        }
    }

    return;
}

override two_barriers => sub {
    my $self = shift;

    return 1;
};

sub _build_low_barrier {
    my $self = shift;

    my $barrier;
    $barrier = $self->make_barrier($self->spot_min);

    return $barrier;
}

sub _build_high_barrier {
    my $self = shift;

    my $barrier;
    $barrier = $self->make_barrier($self->spot_max);

    return $barrier;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
