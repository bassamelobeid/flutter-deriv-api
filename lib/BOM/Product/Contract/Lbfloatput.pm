package BOM::Product::Contract::Lbfloatput;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Lookback', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

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
        my ($high) = @{$self->get_ohlc_for_period()}{qw(high)};
        if (defined $high) {
            my $value = ($high - $self->exit_tick->quote) * $self->multiplier;
            $self->value($value);

            warn "Negative value for lookback: "
                . $self->shortcode
                . " high:"
                . $high
                . " exit tick:"
                . $self->exit_tick->quote
                . " exit tick epoch: "
                . $self->exit_tick->epoch
                if $value < 0;
        }

    }

    return;
}

sub _build_barrier {
    my $self = shift;

    return $self->make_barrier($self->spot_min_max($self->date_start_plus_1s)->{high}, {barrier_kind => 'high'});
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

