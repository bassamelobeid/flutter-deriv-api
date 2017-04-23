package BOM::Product::Contract::Calle;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use BOM::Product::Static;

sub code { return 'CALLE'; }

sub localizable_description {
    return +{
        tick                  => BOM::Product::Static::get_longcodes()->{calle_tick},
        daily                 => BOM::Product::Static::get_longcodes()->{calle_daily},
        intraday              => BOM::Product::Static::get_longcodes()->{calle_intraday},
        intraday_fixed_expiry => BOM::Product::Static::get_longcodes()->{calle_intraday_fixed_expiry},
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
