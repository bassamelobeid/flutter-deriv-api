package BOM::Product::Contract::Notouch;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::AmericanExpiry';

sub code { return 'NOTOUCH'; }

sub ticks_to_expiry {
    die 'no ticks_to_expiry on a NOTOUCH contract';
}

sub localizable_description {
    return +{
        daily                 => 'Win payout if [_3] does not touch [_6] through [_5].',
        intraday              => 'Win payout if [_3] does not touch [_6] through [_5] after [_4].',
        intraday_fixed_expiry => 'Win payout if [_3] does not touch [_6] through [_5].',
    };
}

sub check_expiry_conditions {
    my $self = shift;

    my ($high, $low, $expired) = $self->get_high_low_for_contract_period();
    if (defined $high and defined $low) {
        my $barrier = $self->barrier->as_absolute;
        my $value   = 0;
        if ($high >= $barrier && $low <= $barrier) {
            $value   = 0;
            $expired = 1;
        } elsif ($expired) {
            $value = $self->payout;
        }
        $self->value($value);
    }

    return $expired;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
