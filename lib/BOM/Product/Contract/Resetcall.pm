package BOM::Product::Contract::Resetcall;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub ticks_to_expiry {
    # Add one since we want N ticks *after* the entry spot
    return shift->tick_count + 1;
}

sub _build_barrier {
    my $self    = shift;
    my $barrier = $self->make_barrier($self->supplied_barrier);

    if ($self->date_pricing->epoch >= $self->date_start->epoch + $self->reset_time->seconds) {
        my $reset_spot = $self->underlying->tick_at($self->date_start->epoch + $self->reset_time->seconds, {allow_inconsistent => 1});
        if ($self->reset_spot->quote < $self->barrier->as_absolute) {
            #If it is OTM, reset to a new barrier
            $barrier = $self->make_barrier($reset_spot->quote);
        }
    }

    return $barrier;
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my $value = ($self->exit_tick->quote > $self->barrier->as_absolute) ? $self->payout : 0;
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
