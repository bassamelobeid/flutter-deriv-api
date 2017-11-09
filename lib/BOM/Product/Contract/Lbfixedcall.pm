package BOM::Product::Contract::Lbfixedcall;

use Moose;
use List::Util qw(max);
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Lookback', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub code { return 'LBFIXEDCALL'; }

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my ($high) = @{$self->get_ohlc_for_period()}{qw(high)};
        if (defined $high) {
            my $value = max(0, $high - $self->barrier->as_absolute);
            $self->value($value);
        }
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
