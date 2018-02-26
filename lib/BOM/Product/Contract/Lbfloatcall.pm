package BOM::Product::Contract::Lbfloatcall;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Lookback', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick and $self->is_valid_exit_tick) {
        my ($low) = @{$self->get_ohlc_for_period()}{qw(low)};
        if (defined $low) {
            my $value = ($self->exit_tick->quote - $low) * $self->multiplier;
            $self->value($value);
        }
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
