package BOM::Product::Contract::Expirymiss;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::DoubleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use BOM::Product::Static qw/get_longcodes/;

sub ticks_to_expiry {
    die 'no ticks_to_expiry on an EXPIRYMISS contract';
}

sub localizable_description {
    return +{
        daily                 => get_longcodes()->{expirymiss_daily},
        intraday              => get_longcodes()->{expirymiss_intraday},
        intraday_fixed_expiry => get_longcodes()->{expirymiss_intraday_fixed_expiry},
    };
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my $exit_spot = $self->exit_tick->quote;
        my $value = ($exit_spot >= $self->low_barrier->as_absolute and $exit_spot <= $self->high_barrier->as_absolute) ? 0 : $self->payout;
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
