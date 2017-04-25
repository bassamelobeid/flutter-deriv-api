package BOM::Product::Contract::Put;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

# Static methods

sub ticks_to_expiry {
    return shift->tick_count + 1;
}

sub localizable_description {
    return +{
        tick                  => 'Win payout if [_3] after [plural,_5,%d tick,%d ticks] is strictly lower than [_6].',
        daily                 => 'Win payout if [_3] is strictly lower than [_6] at [_5].',
        intraday              => 'Win payout if [_3] is strictly lower than [_6] at [_5] after [_4].',
        intraday_fixed_expiry => 'Win payout if [_3] is strictly lower than [_6] at [_5].',
    };
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my $value = ($self->exit_tick->quote < $self->barrier->as_absolute) ? $self->payout : 0;
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
