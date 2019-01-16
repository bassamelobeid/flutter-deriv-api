package BOM::Product::Role::HighLowRuns;

use strict;
use warnings;

use Moose::Role;
use BOM::Product::Pricing::Greeks::ZeroGreek;
use BOM::Product::Exception;

sub BUILD {
    my $self = shift;

    if (not $self->for_sale and defined $self->supplied_barrier and $self->supplied_barrier !~ /^S0P$/) {
        BOM::Product::Exception->throw(error_code => 'InvalidBarrier');
    }

    return;
}

has selected_tick => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_selected_tick {
    my $self = shift;
    return $self->tick_count // BOM::Product::Exception->throw(error_code => 'TradingDurationNotAllowed');
}

sub ticks_to_expiry {
    my $self = shift;
    return $self->selected_tick + 1;
}

sub _build_pricing_engine_name {
    return 'Pricing::Engine::HighLow::Runs';
}

sub _build_greek_engine {
    return BOM::Product::Pricing::Greeks::ZeroGreek->new({bet => shift});
}

# get ticks from redis cache.
sub _get_ticks_since_start {
    my $self = shift;

    # contract is only started when entry tick is defined.
    return [] unless $self->entry_tick;

    my $from  = $self->date_start->epoch + 1;                      # first tick is next tick
    my $ticks = $self->underlying->ticks_in_between_start_limit({
        start_time => $from,
        limit      => $self->ticks_to_expiry,
    });

    return $ticks;
}

sub get_impermissible_inputs {
    return {
        # Contract-irrelevant inputs
        'barrier2'      => 1,
        'selected_tick' => 1,
    };
}

has _hit_tick => (
    is => 'rw',
);

sub _build_hit_tick {
    my $self = shift;
    return $self->_hit_tick();
}
1;
