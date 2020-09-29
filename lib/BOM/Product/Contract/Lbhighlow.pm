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

    if ($self->exit_tick and $self->is_valid_exit_tick) {
        my ($high, $low) = @{$self->get_ohlc_for_period()}{qw(high low)};
        #The hypothesis we have right now is, since exit tick came from Redis and OHLC is from db,
        #when we request the OHLC, the exit tick is not part of the OHLC yet in the DB.
        if (defined $high and defined $low and $self->exit_tick->quote <= $high and $self->exit_tick->quote >= $low) {
            my $value = ($high - $low) * $self->multiplier;
            $self->value($value);
        } else {
            $self->waiting_for_settlement_tick(1);
            $self->_add_error({
                message           => "Inconsistent OHLC.",
                message_to_client => [$self->waiting_for_settlement_error_message()],
            });
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
