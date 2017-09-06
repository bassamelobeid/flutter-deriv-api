package BOM::Product::Contract::Calle;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use BOM::Product::Static qw/get_longcodes/;
use BOM::Product::Exception;

sub ticks_to_expiry {
    my $self = shift;

    BOM::Product::Exception->throw(
        error_code => 'InvalidTickExpiry',
        error_args => [$self->code],
    );
}

sub localizable_description {
    return +{
        tick                  => get_longcodes()->{calle_tick},
        daily                 => get_longcodes()->{calle_daily},
        intraday              => get_longcodes()->{calle_intraday},
        intraday_fixed_expiry => get_longcodes()->{calle_intraday_fixed_expiry},
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
