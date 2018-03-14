package BOM::Product::Contract::Ticklow;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Binary', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::AmericanExpiry';

use List::Util qw/any min/;

use Pricing::Engine::HighLowTicks;

use BOM::Product::Pricing::Greeks::ZeroGreek;

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
    my @shortcode_elements = ($self->code, $self->underlying->symbol, $self->payout + 0, $self->date_start->epoch, $self->tick_count . 't', $self->selected_tick);

    return join '_', @shortcode_elements
};

sub check_expiry_conditions {

    my $self = shift;

    my $ticks = $self->underlying->ticks_in_between_start_limit({
        start_time => $self->date_start->epoch + 1,
        limit      => DURATION_IN_TICKS,
    });

    my $number_of_ticks = scalar(@$ticks);

    # If there's no tick yet, the contract is not expired.
    return 0 if $number_of_ticks < $self->selected_tick;

    my $selected_quote = $ticks->[$self->selected_tick - 1]->{quote};

    # selected quote is not the lowest.
    if (any { $_->{quote} < $selected_quote } @$ticks) {
        $self->value(0);
        return 1;    # contract expired
    }

    # we already have the full set of ticks, but no tick is lower than selected.
    if ($number_of_ticks == DURATION_IN_TICKS) {
        $self->value($self->payout);
        return 1;
    }

    # not expired, still waiting for ticks.
    return 0;

}

sub _validate_barrier {
    return;    # override barrier validation
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
