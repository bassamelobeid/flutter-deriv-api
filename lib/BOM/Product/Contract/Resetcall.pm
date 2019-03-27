package BOM::Product::Contract::Resetcall;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use BOM::Product::Pricing::Greeks::ZeroGreek;

sub _build_greek_engine {
    return BOM::Product::Pricing::Greeks::ZeroGreek->new({bet => shift});
}

sub ticks_to_expiry {
    # Add one since we want N ticks *after* the entry spot
    return shift->tick_count + 1;
}

sub _build_barrier {
    my $self = shift;
    my $barrier = $self->make_barrier($self->supplied_barrier, {barrier_kind => 'high'});

    if ($self->reset_spot and $self->reset_spot->quote < $barrier->as_absolute) {
        #If it is OTM, reset to a new barrier
        $barrier = $self->make_barrier($self->reset_spot->quote, {barrier_kind => 'high'});
    }

    return $barrier;
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick) {
        my $value = ($self->exit_tick->quote > $self->barrier->as_absolute) ? $self->payout : 0;
        $self->value($value);
    }

    return undef;
}

sub _build_pricing_engine_name {
    return 'Pricing::Engine::Reset';
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
