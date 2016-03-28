package BOM::Product::Contract::Expirymisse;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::DoubleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub code { return 'EXPIRYMISSE'; }

sub localizable_description {
    return +{
        daily                 => '[_1] [_2] payout if [_3] ends on or outside [_7] to [_6] at [_5].',
        intraday              => '[_1] [_2] payout if [_3] ends on or outside [_7] to [_6] at [_5] after [_4].',
        intraday_fixed_expiry => '[_1] [_2] payout if [_3] ends on or outside [_7] to [_6] at [_5].',
    };
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my $exit_spot = $self->exit_tick->quote;
        my $value = ($exit_spot > $self->low_barrier->as_absolute and $exit_spot < $self->high_barrier->as_absolute) ? 0 : $self->payout;
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
