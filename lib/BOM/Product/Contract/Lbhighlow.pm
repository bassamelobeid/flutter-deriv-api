package BOM::Product::Contract::Lbhighlow;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Lookback', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub code { return 'LBHIGHLOW'; }

sub localizable_description {
    return +{
        intraday => 'Receive the difference of [_3]\'s maximum and minimum value during the life of the option at [_5] after [_4].',
    };
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my ($high, $low) = @{$self->get_ohlc_for_period()}{qw(high low)};
        die "High/Low is not available for symbol: " . $self->underlying->symbol if (not defined $high or not defined $low);
        my $value = $high - $low;
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
