package BOM::Product::Role::Vanilla;

use Moose::Role;
use Time::Duration::Concise;
use Format::Util::Numbers qw/financialrounding formatnumber/;

=head2 _build_pricing_engine_name

Returns pricing engine name

=cut

sub _build_pricing_engine_name {
    return 'BOM::Product::Pricing::Engine::BlackScholes';
}

=head2 _build_pricing_engine

Returns pricing engine used to price contract

=cut

sub _build_pricing_engine {
    return BOM::Product::Pricing::Engine::BlackScholes->new({bet => shift});
}

has [qw(
        bid_probability
        ask_probability
        theo_probability
    )
] => (
    is         => 'ro',
    isa        => 'Math::Util::CalculatedValue::Validatable',
    lazy_build => 1,
);

has number_of_contracts => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_number_of_contracts',
);

=head2 _build_number_of_contracts

Calculate implied number of contracts.
n = Stake / Option Price

We need to use entry tick to calculate this figure.

=cut

sub _build_number_of_contracts {
    my $self = shift;

    # limit to 5 decimal points
    return sprintf("%.5f", $self->_user_input_stake / $self->_build_ask_probability->amount);
}

=head2 _build_theo_probability

Calculates the theoretical blackscholes option price (no markup)

=cut

sub _build_theo_probability {
    my $self = shift;

    $self->clear_pricing_engine;
    return $self->pricing_engine->probability;
}

=head2 _build_ask_probability

Adds markup to theoretical blackscholes option price

=cut

sub _build_ask_probability {
    my $self = shift;

    my $ask_probability = do {
        local $self->_pricing_args->{iv} = $self->pricing_vol + 0.025;

        # don't wrap them in one scope as the changes will be reverted out of scope
        local $self->_pricing_args->{spot} = $self->entry_tick->quote                                        unless $self->pricing_new;
        local $self->_pricing_args->{t}    = $self->calculate_timeindays_from($self->date_start)->days / 365 unless $self->pricing_new;

        $self->_build_theo_probability;
    };
    return $ask_probability;
}

=head2 _build_bid_probability

Adds markup to theoretical blackscholes option price

=cut

sub _build_bid_probability {
    my $self = shift;

    my $ask_probability = do {
        local $self->_pricing_args->{iv} = $self->pricing_vol - 0.025;
        $self->_build_theo_probability;
    };

    return $ask_probability;
}

override _build_app_markup_dollar_amount => sub {
    return 0;
};

override _build_bid_price => sub {
    my $self = shift;

    return undef if $self->pricing_new;
    return financialrounding('price', $self->currency, $self->bid_probability->amount * $self->number_of_contracts);
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

=head2 _build_payout

For vanilla options it is not possible to define payout.

=cut

sub _build_payout {
    return 0;
}

override _build_entry_tick => sub {
    my $self = shift;
    my $tick = $self->_tick_accessor->tick_at($self->date_start->epoch);

    return $tick if defined($tick);
    return $self->current_tick;
};

1;
