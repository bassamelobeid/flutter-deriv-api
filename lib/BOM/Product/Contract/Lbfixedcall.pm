package BOM::Product::Contract::Lbfixedcall;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Lookback', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub code { return 'LBFIXEDCALL'; }

sub localizable_description {
    return +{
        intraday => 'Receive the difference of [_3]\'s maximum value during the life of the option and [_6] at [_5] after [_4].',
    };
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my ($high) = @{$self->get_ohlc_for_period()}{qw(high)};
        die "High is not available for symbol: " . $self->underlying->symbol if not defined $high;
        my $value = $high - $self->barrier->as_absolute;
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
