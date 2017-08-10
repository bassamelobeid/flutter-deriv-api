package BOM::Product::Contract::Put;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use BOM::Product::Static qw/get_longcodes/;

sub ticks_to_expiry {
    # Add one since we want N ticks *after* the entry spot
    return shift->tick_count + 1;
}

sub localizable_description {
    return +{
        tick                  => get_longcodes()->{put_tick},
        daily                 => get_longcodes()->{put_daily},
        intraday              => get_longcodes()->{put_intraday},
        intraday_fixed_expiry => get_longcodes()->{put_intraday_fixed_expiry},
    };
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my $value = ($self->exit_tick->quote < $self->barrier->as_absolute) ? $self->payout : 0;
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
