package BOM::Product::Contract::Lbfloatput;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Lookback', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub code { return 'LBFLOATPUT'; }

sub localizable_description {
    return +{
        intraday => 'Receive the difference of [_3]\'s maximum value during the life of the option and its final value at [_5] after [_4].',
    };
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my ($high, $close) = @{$self->get_ohlc_for_period()}{qw(high close)};
        my $value = $high - $close;
        $self->value($value);
    }

    return;
}

sub _build_pricing_engine_name {
    return 'Pricing::Engine::Lookback';
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

