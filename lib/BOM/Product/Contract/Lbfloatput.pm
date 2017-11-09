package BOM::Product::Contract::Lbfloatput;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Lookback', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub code { return 'LBFLOATPUT'; }

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my ($high, $close) = @{$self->get_ohlc_for_period()}{qw(high close)};
        if (defined $high and defined close) {
            my $value = $high - $close;
            $self->value($value);
        }
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

