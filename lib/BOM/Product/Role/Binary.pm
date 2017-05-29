package BOM::Product::Role::Binary;

use Moose::Role;

sub _build_payout {
    my ($self) = @_;

    $self->_set_price_calculator_params('payout');
    return $self->price_calculator->payout;
}

1;
