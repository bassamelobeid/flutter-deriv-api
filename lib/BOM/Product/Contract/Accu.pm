package BOM::Product::Contract::Accu;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Accumulator';

=head2 check_expiry_conditions

set contract value after it expires

=cut

sub check_expiry_conditions {
    my $self = shift;

    if ($self->hit_tick) {
        $self->value(0);
    } else {
        $self->value($self->calculate_payout($self->ticks_to_expiry));
    }
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
