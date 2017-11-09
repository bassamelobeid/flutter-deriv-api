package BOM::Product::Contract::Lbfixedput;

use Moose;
use List::Util qw(max);
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Lookback', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub code { return 'LBFIXEDPUT'; }

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my ($low) = @{$self->get_ohlc_for_period()}{qw(low)};
        if (defined $low) {
            my $value = max(0, $self->barrier->as_absolute - $low);
            $self->value($value);
        }
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
