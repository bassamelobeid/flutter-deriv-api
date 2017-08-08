package BOM::Product::Contract::Lbfixedput;

use Moose;
use List::Util qw(max);
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Lookback', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub code { return 'LBFIXEDPUT'; }

sub localizable_description {
    return +{
        intraday => 'Receive the difference of [_6] and [_3]\'s minimum value during the life of the option at [_5] after [_4].',
    };
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my ($low) = @{$self->get_ohlc_for_period()}{qw(low)};
        die "Low is not defined for symbol: " . $self->underlying->symbol if not defined $low;
        my $value = max(0, $self->barrier->as_absolute - $low);
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
