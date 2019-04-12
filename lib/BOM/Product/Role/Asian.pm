package BOM::Product::Role::Asian;

use strict;
use warnings;

use Moose::Role;

sub ticks_to_expiry {
    return shift->tick_count;
}

sub _build_pricing_engine_name {
    return 'Pricing::Engine::BlackScholes';
}

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
        $barrier = $self->make_barrier($self->supplied_barrier, {custom_pipsize => $custom_pipsize});
    }

    return $barrier;
}

1;
