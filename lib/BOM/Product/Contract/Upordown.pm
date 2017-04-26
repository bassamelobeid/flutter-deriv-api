package BOM::Product::Contract::Upordown;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::DoubleBarrier', 'BOM::Product::Role::AmericanExpiry';

use BOM::Product::Static;

sub ticks_to_expiry {
    die 'no ticks_to_expiry on an UPORDOWN contract';
}

sub localizable_description {
    return +{
        daily                 => BOM::Product::Static::get_longcodes()->{upordown_daily},
        intraday              => BOM::Product::Static::get_longcodes()->{upordown_intraday},
        intraday_fixed_expiry => BOM::Product::Static::get_longcodes()->{upordown_intraday_fixed_expiry},
    };
}

sub check_expiry_conditions {
    my $self = shift;

    my ($high, $low, $expired) = $self->get_high_low_for_contract_period();
    if (defined $high and defined $low) {
        my $value        = 0;
        my $high_barrier = $self->high_barrier->as_absolute;
        my $low_barrier  = $self->low_barrier->as_absolute;
        if (($high >= $high_barrier && $low <= $high_barrier) || ($high >= $low_barrier && $low <= $low_barrier)) {
            $expired = 1;
            $value   = $self->payout;
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
