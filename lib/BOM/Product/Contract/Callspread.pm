package BOM::Product::Contract::Callspread;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Bullspread';

override '_build_bid_price' => sub {
    my $self = shift;

    return $self->_calculate_price_for({
        spot    => $self->current_spot,
        strikes => [$self->current_spot, $self->low_barrier->as_absolute],
    });
};

sub check_expiry_conditions {
    my $self = shift;

    my $contract_value = 0;
    if ($self->exit_tick) {
        my $value = ($self->exit_tick->quote - $self->low_barrier->as_absolute) * $self->multiplier;
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
