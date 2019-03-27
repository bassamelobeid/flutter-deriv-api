package BOM::Product::Contract::Lbhighlow;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Lookback', 'BOM::Product::Role::DoubleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use BOM::Product::Exception;

sub ticks_to_expiry {
    my $self = shift;

    return BOM::Product::Exception->throw(
        error_code => 'InvalidTickExpiry',
        error_args => [$self->code],
        details    => {field => 'duration'},
    );
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my ($high, $low) = @{$self->get_ohlc_for_period()}{qw(high low)};
        if (defined $high and defined $low) {
            my $value = ($high - $low) * $self->multiplier;
            $self->value($value);

            warn "Negative value for lookback: " . $self->shortcode . " low:" . $low . " high:" . $high if $value < 0;
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

    return $self->make_barrier($self->spot_min_max($self->date_start_plus_1s)->{low}, {barrier_kind => 'low'});
}

sub _build_high_barrier {
    my $self = shift;

    return $self->make_barrier($self->spot_min_max($self->date_start_plus_1s)->{high}, {barrier_kind => 'high'});
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
