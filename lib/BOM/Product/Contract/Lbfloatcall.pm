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

    my ($low, $close);

    my $start_epoch = $self->date_start->epoch + 1;    # excluding tick at contract start time

    my $end_epoch;

    if ($self->date_pricing->is_after($self->date_expiry)) {
        $end_epoch = $self->expiry_daily ? $self->date_expiry->truncate_to_day->epoch : $self->date_settlement->epoch;
    } else {
        $end_epoch = $self->date_pricing->epoch;
    }

    ($low, $close) = @{
        $self->underlying->get_high_low_for_period({
                start => $start_epoch,
                end   => $end_epoch,
            })}{'low', 'close'};

    if ($self->exit_tick) {
        my $value = $close - $low;
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
