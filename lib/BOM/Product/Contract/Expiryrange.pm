package BOM::Product::Contract::Expiryrange;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::DoubleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use BOM::Product::Static;

sub code { return 'EXPIRYRANGE'; }

sub localizable_description {
    return +{
        daily                 => BOM::Product::Static::get_longcodes()->{expiryrange_daily},
        intraday              => BOM::Product::Static::get_longcodes()->{expiryrange_intraday},
        intraday_fixed_expiry => BOM::Product::Static::get_longcodes()->{expiryrange_intraday_fixed_expiry},
    };
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my $exit_spot = $self->exit_tick->quote;
        my $value = ($exit_spot < $self->high_barrier->as_absolute and $exit_spot > $self->low_barrier->as_absolute) ? $self->payout : 0;
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
