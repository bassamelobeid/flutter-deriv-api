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

no Moose;
__PACKAGE__->meta->make_immutable;
1;
