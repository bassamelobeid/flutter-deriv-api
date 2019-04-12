package BOM::Product::Contract::Upordown;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::DoubleBarrier', 'BOM::Product::Role::AmericanExpiry';

use BOM::Product::Exception;

sub ticks_to_expiry {
    my $self = shift;

    return BOM::Product::Exception->throw(
        error_code => 'InvalidTickExpiry',
        error_args => [$self->code],
        details    => {fields => 'duration'},
    );
}

sub check_expiry_conditions {
    my $self = shift;

    my $value = $self->hit_tick ? $self->payout : 0;
    $self->value($value);

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
