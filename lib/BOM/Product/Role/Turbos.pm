package BOM::Product::Role::Turbos;

use Moose::Role;
use Time::Duration::Concise;
use Format::Util::Numbers qw/financialrounding formatnumber/;

use constant {
    AVG_TICK_SIZE_UP      => 0.00017807243465445342,
    TICKS_COMMISSION_UP   => 1,
    AVG_TICK_SIZE_DOWN    => 0.00017807243465445342,
    TICKS_COMMISSION_DOWN => 1,
};

=head2 _build_pricing_engine_name

Returns pricing engine name

=cut

sub _build_pricing_engine_name {
    return '';
}

=head2 _build_pricing_engine

Returns pricing engine used to price contract

=cut

sub _build_pricing_engine {
    return undef;
}

has [qw(
        bid_probability
        ask_probability
    )
] => (
    is         => 'ro',
    isa        => 'Math::Util::CalculatedValue::Validatable',
    lazy_build => 1,
);

# has [qw(max_duration duration max_payout take_profit tick_count tick_size_barrier basis_spot tick_count_after_entry pnl)] => (
has [qw(hit_tick number_of_contracts)] => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 AVG_TICK_SIZE_UP

remove later

=cut

=head2 AVG_TICK_SIZE_DOWN

remove later

=cut

=head2 TICKS_COMMISSION_UP

remove later

=cut

=head2 TICKS_COMMISSION_DOWN

remove later

=cut

=head2 theo_ask_probability

Calculates the theoretical blackscholes option price (no markup)

=cut

sub theo_ask_probability {
    my ($self, $tick) = @_;

    $tick //= $self->entry_tick;
    my $ask_spread = AVG_TICK_SIZE_UP * TICKS_COMMISSION_UP;
    my $ask_price  = $tick->quote * (1 + $ask_spread);

    return $ask_price;
}

=head2 theo_bid_probability

Calculates the theoretical blackscholes option price (no markup)

=cut

sub theo_bid_probability {
    my ($self, $tick) = @_;

    $tick //= $self->entry_tick;
    # if ($self->date_pricing) {
    #     $tick = $self->underlying->tick_at($self->date_pricing->epoch);
    # }
    my $bid_spread = AVG_TICK_SIZE_DOWN * TICKS_COMMISSION_DOWN;
    my $bid_price  = $tick->quote * (1 - $bid_spread);

    return $bid_price;
}

=head2 _build_number_of_contracts

Calculate implied number of contracts.
n = Stake / Option Price
We need to use entry tick to calculate this figure.

=cut

sub _build_number_of_contracts {
    my $self = shift;

    # limit to 5 decimal points
    return sprintf("%.5f", $self->_user_input_stake / $self->_contract_price);
}

override _build_app_markup_dollar_amount => sub {
    return 0;
};

=head2 bid_price

Bid price which will be saved into sell_price in financial_market_bet table.

=cut

override '_build_bid_price' => sub {
    my $self = shift;
    return $self->sell_price if $self->is_sold;
    return $self->value      if $self->is_expired;
    return $self->calculate_payout();
};

override '_build_ask_price' => sub {
    my $self = shift;
    return $self->_user_input_stake;
};

override 'shortcode' => sub {
    my $self = shift;

    return join '_',
        (
        uc $self->code,
        uc $self->underlying->symbol,
        financialrounding('price', $self->currency, $self->_user_input_stake),
        $self->date_start->epoch,
        $self->date_expiry->epoch,
        $self->_barrier_for_shortcode_string($self->supplied_barrier),
        $self->number_of_contracts
        );
};

override _build_entry_tick => sub {
    my $self = shift;
    my $tick = $self->_tick_accessor->tick_at($self->date_start->epoch);

    return $tick if defined($tick);
    return $self->current_tick;
};

=head2 _build_hit_tick

initializing hit_tick attribute

=cut

sub _build_hit_tick {
    my $self = shift;

    # date_start + 1 applies for all expiry type (tick, intraday & multi-day). Basically the first tick
    # that comes into play is the tick after the contract start time, not at the contract start time.
    return undef unless $self->entry_tick;

    my @ticks_since_start = @{$self->ticks_for_tick_expiry};
    my $prev_spot         = $self->entry_tick->quote;

    #returns the first tick on which one of the barriers is hit
    for my $tick (@ticks_since_start) {

        return $tick if $self->_check_barrier_crossed($tick->quote);

        $prev_spot = $tick->quote;
    }

    return undef;
}

=head2 ticks_to_expiry

The number of ticks required from contract start time to expiry.

=cut

sub ticks_to_expiry {
    my $self = shift;

    return $self->tick_count;
}

=head2 _build_payout

For vanilla options it is not possible to define payout.

=cut

sub _build_payout {
    return 0;
}

1;
