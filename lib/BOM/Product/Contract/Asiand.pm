package BOM::Product::Contract::Asiand;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

sub ticks_to_expiry {
    return shift->tick_count;
}

sub _build_pricing_engine_name {
    return 'Pricing::Engine::BlackScholes';
}

has supplied_barrier => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_supplied_barrier {
    my $self = shift;

    # barrier is undef on asians before the contract starts.
    return if $self->pricing_new;

    my $hmt               = $self->tick_count;
    my @ticks_since_start = @{
        $self->underlying->ticks_in_between_start_limit({
                start_time => $self->date_start->epoch + 1,
                limit      => $hmt,
            })};

    return unless @ticks_since_start;
    return if $self->is_after_settlement and $hmt != @ticks_since_start;

    my $sum = 0;
    for (@ticks_since_start) {
        $sum += $_->quote;
    }

    my $supp = $sum / @ticks_since_start;

    return $supp;
}

sub _build_barrier {
    my $self = shift;

    my $barrier;
    if ($self->supplied_barrier) {
        my $custom_pipsize = $self->underlying->pip_size / 10;
        $barrier = $self->make_barrier(
            $self->supplied_barrier,
            {
                custom_pipsize => $custom_pipsize,
                barrier_kind   => 'high',
            });
    }

    return $barrier;
}

sub check_expiry_conditions {
    my $self = shift;

    if ($self->exit_tick and $self->barrier) {
        my $value = ($self->exit_tick->quote < $self->barrier->as_absolute) ? $self->payout : 0;
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
