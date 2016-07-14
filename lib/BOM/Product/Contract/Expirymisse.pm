package BOM::Product::Contract::Expirymisse;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::DoubleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use BOM::Platform::Context qw(localize);

sub code { return 'EXPIRYMISSE'; }

sub localizable_description {
    return +{
        daily                 => localize('Win payout if [_3] ends on or outside [_7] to [_6] at [_5].'),
        intraday              => localize('Win payout if [_3] ends on or outside [_7] to [_6] at [_5] after [_4].'),
        intraday_fixed_expiry => localize('Win payout if [_3] ends on or outside [_7] to [_6] at [_5].'),
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
