package BOM::Product::Contract::Putspread;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Bullspread';

override '_build_bid_price' => sub {
    my $self = shift;

    return $self->_calculate_price_for({
        spot    => $self->current_spot,
        strikes => [$self->high_barrier->as_absolute, $self->current_spot],
    });
};

sub check_expiry_conditions {
    my $self = shift;

    my $contract_value = 0;
    if ($self->exit_tick) {
        my $value = ($self->high_barrier->as_absolute - $self->exit_tick->quote) * $self->multiplier;
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
