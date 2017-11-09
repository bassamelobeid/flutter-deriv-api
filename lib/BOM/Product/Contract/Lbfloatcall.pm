package BOM::Product::Contract::Lbfloatcall;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Lookback', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub code { return 'LBFLOATCALL'; }

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my ($low, $close) = @{$self->get_ohlc_for_period()}{qw(low close)};
        if (defined $low and defined $close) {
            my $value = $close - $low;
            $self->value($value);
        }
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
