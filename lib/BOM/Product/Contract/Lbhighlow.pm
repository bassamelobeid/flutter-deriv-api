package BOM::Product::Contract::Lbhighlow;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Lookback', 'BOM::Product::Role::DoubleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my ($high, $low) = @{$self->get_ohlc_for_period()}{qw(high low)};
        if (defined $high and defined $low) {
            my $value = ($high - $low) * $self->multiplier;
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

    return $self->make_barrier($self->spot_min_max->{low});
}

sub _build_high_barrier {
    my $self = shift;

    return $self->make_barrier($self->spot_min_max->{high});
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
