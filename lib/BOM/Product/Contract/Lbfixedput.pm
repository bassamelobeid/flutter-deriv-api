package BOM::Product::Contract::Lbfixedput;

use Moose;
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
        my $value = $self->barrier - $low;
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
