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
        my @ticks = @{
            $self->_tick_accessor->ticks_in_between_start_limit({
                    start_time => $self->date_start->epoch + 1,
                    limit      => $self->ticks_to_expiry
                })};
        my $low  = $self->get_low_barrier($ticks[-2]->quote);
        my $high = $self->get_high_barrier($ticks[-2]->quote);

        my $value = ($self->exit_tick->quote < $high && $self->exit_tick->quote > $low) ? $self->calculate_payout(scalar @ticks) : 0;

        $self->value($value);
    }
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
