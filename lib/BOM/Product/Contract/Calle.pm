package BOM::Product::Contract::Calle;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use BOM::Platform::Context qw(localize);

# Static methods

sub code { return 'CALLE'; }

sub ticks_to_expiry {
    die 'no ticks_to_expiry on a CALLE contract';
}

sub localizable_description {
    return +{
        tick                  => 'Win payout if [_3] after [plural,_5,%d tick,%d ticks] is higher than or equal to [_6].',
        daily                 => 'Win payout if [_3] is higher than or equal to [_6] at [_5].',
        intraday              => 'Win payout if [_3] is higher than or equal to [_6] at [_5] after [_4].',
        intraday_fixed_expiry => 'Win payout if [_3] is higher than or equal to [_6] at [_5].',
    };
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my $value = ($self->exit_tick->quote >= $self->barrier->as_absolute) ? $self->payout : 0;
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
