package BOM::Product::Contract::Lbfloatcall;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Lookback', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub code { return 'LBFLOATCALL'; }

sub localizable_description {
    return +{
        intraday => 'Receive the difference of [_3]\'s final value and its minimum value during the life of the option at [_5] after [_4].',
    };
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my ($low, $close) = @{$self->get_ohlc_for_period()}{qw(low close)};
        die "Low/Close is not available for symbol: " . $self->underlying->symbol if (not defined $low or not defined $close);
        my $value = $close - $low;
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
