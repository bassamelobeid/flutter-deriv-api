package BOM::Product::Contract::Onetouch;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::AmericanExpiry';

sub code { return 'ONETOUCH'; }

sub localizable_description {
    return +{
        daily                 => '[_1] [_2] payout if [_3] touches [_6] through [_5].',
        intraday              => '[_1] [_2] payout if [_3] touches [_6] through [_5] after [_4].',
        intraday_fixed_expiry => '[_1] [_2] payout if [_3] touches [_6] through [_5].',
    };
}

sub check_expiry_conditions {
    my $self = shift;

    my ($high, $low, $expired) = $self->get_high_low_for_contract_period();
    if (defined $high and defined $low) {
        my $barrier = $self->barrier->as_absolute;
        my $value   = 0;
        if ($high >= $barrier && $low <= $barrier) {
            $value   = $self->payout;
            $expired = 1;
        } elsif ($expired) {
            $value = 0;
        }
        $self->value($value);
    }

    return $expired;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
