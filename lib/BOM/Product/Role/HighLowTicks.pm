package BOM::Product::Role::HighLowTicks;

use Moose::Role;

use constant DURATION_IN_TICKS => 5;

has 'selected_tick' => (
    is       => 'ro',
    required => 1,
);

# Required to determine the exit tick
sub ticks_to_expiry {
    return DURATION_IN_TICKS;
}

sub _build_pricing_engine_name {
    return 'Pricing::Engine::HighLowTicks';
}

sub _build_greek_engine {
    return BOM::Product::Pricing::Greeks::ZeroGreek->new({bet => shift});
}

sub _build_selected_tick {
    my $self = shift;

    return BOM::Product::Exception->throw(
        error_code => 'MissingRequiredSelectedTick',
    );
}

override shortcode => sub {
    my $self = shift;
    return join '_', ($self->code, $self->underlying->symbol, $self->payout + 0, $self->date_start->epoch, $self->tick_count . 't', $self->selected_tick);
};

1;
