package BOM::Product::Contract::Notouch;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::AmericanExpiry';

use BOM::Product::Static;

sub code { return 'NOTOUCH'; }

sub localizable_description {
    return +{
        daily                 => BOM::Product::Static::get_longcodes()->{notouch_daily},
        intraday              => BOM::Product::Static::get_longcodes()->{notouch_intraday},
        intraday_fixed_expiry => BOM::Product::Static::get_longcodes()->{notouch_intraday_fixed_expiry},
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
