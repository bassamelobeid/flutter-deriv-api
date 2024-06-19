package BOM::Product::Role::HighLowRuns;

use strict;
use warnings;

use Moose::Role;
use BOM::Product::Pricing::Greeks::ZeroGreek;
use BOM::Product::Exception;

sub BUILD {
    my $self = shift;

    if (not $self->for_sale and defined $self->supplied_barrier and $self->supplied_barrier !~ /^S0P$/) {
        BOM::Product::Exception->throw(
            error_code => 'InvalidBarrier',
            details    => {field => 'barrier'},
        );
    }

    return;
}

has selected_tick => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_selected_tick {
    my $self = shift;
    return $self->tick_count // BOM::Product::Exception->throw(
        error_code => 'TradingDurationNotAllowed',
        details    => {field => 'duration'},
    );
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

has _all_ticks => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__all_ticks {
    my $self = shift;

    return [] unless $self->entry_tick;

    return $self->_tick_accessor->ticks_in_between_start_limit({
        start_time => $self->date_start->epoch + 1,
        limit      => $self->ticks_to_expiry,
    });
}

1;
