package BOM::Product::Role::HighLowTicks;

use Moose::Role;
use BOM::Product::Exception;
use Scalar::Util::Numeric qw/isint/;

use constant DURATION_IN_TICKS => 5;
use constant MIN_SELECTED_TICK => 1;
use constant MAX_SELECTED_TICK => 5;

sub BUILD {
    my $self = shift;

    if (!isint $self->selected_tick) {
        BOM::Product::Exception->throw(
            error_code => 'IntegerSelectedTickRequired',
        );
    }

    if ($self->selected_tick < MIN_SELECTED_TICK or $self->selected_tick > MAX_SELECTED_TICK) {
        BOM::Product::Exception->throw(
            error_code => 'SelectedTickNumberLimits',
            error_args => [MIN_SELECTED_TICK, MAX_SELECTED_TICK],
        );
    }

    return undef;
}

has 'selected_tick' => (
    is         => 'ro',
    lazy_build => 1,
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

around supplied_barrier => sub {
    my $orig = shift;
    my $self = shift;

    # barrier is undef on asians before the contract starts.
    return if $self->pricing_new;

    my $hmt               = $self->selected_tick;
    my @ticks_since_start = @{
        $self->underlying->ticks_in_between_start_limit({
                start_time => $self->date_start->epoch + 1,
                limit      => $hmt,
            })};

    return unless @ticks_since_start;
    return if $hmt != @ticks_since_start;
    return $ticks_since_start[-1]->{quote};
};

around '_build_barrier' => sub {
    my $orig = shift;
    my $self = shift;

    return unless $self->supplied_barrier;
    return $self->$orig;
};

around '_build_bid_price' => sub {
    my $orig = shift;
    my $self = shift;

    return 0 unless $self->is_expired;
    return $self->$orig;
};

override shortcode => sub {
    my $self = shift;
    return join '_',
        ($self->code, $self->underlying->symbol, $self->payout + 0, $self->date_start->epoch, $self->tick_count . 't', $self->selected_tick);
};

1;
