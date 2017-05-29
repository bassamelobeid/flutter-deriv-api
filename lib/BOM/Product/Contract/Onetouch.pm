package BOM::Product::Contract::Onetouch;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::AmericanExpiry';

use BOM::Product::Static qw/get_longcodes/;

sub ticks_to_expiry {
    die 'no ticks_to_expiry on a ONETOUCH contract';
}

sub localizable_description {
    return +{
        daily                 => get_longcodes()->{onetouch_daily},
        intraday              => get_longcodes()->{onetouch_intraday},
        intraday_fixed_expiry => get_longcodes()->{onetouch_intraday_fixed_expiry},
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
