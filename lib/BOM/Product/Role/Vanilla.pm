package BOM::Product::Role::Vanilla;

use Moose::Role;
use Time::Duration::Concise;
use Format::Util::Numbers qw/financialrounding/;

use POSIX qw(ceil floor);

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

has [qw(min_stake max_stake)] => (
    is         => 'ro',
    lazy_build => 1,
);

has number_of_contracts => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_number_of_contracts',
);

has strike_price_choices => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_strike_price_choices',
);

=head2 _build_min_stake

calculates minimum stake based on values from backoffice

=cut

sub _build_min_stake {
    my $self = shift;

    # hard coding minimum number of contracts for now, values will be from backoffice
    my $n_min = 0.1;

    return ceil($n_min * $self->ask_probability->amount);
}

=head2 _build_max_stake

calculates maximum stake based on values from backoffice

=cut

sub _build_max_stake {
    my $self = shift;

    # hard coding minimum number of contracts for now, values will be from backoffice
    my $n_max = 10;

    return floor($n_max * $self->ask_probability->amount);
}

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

=head2 _build_strike_price_choices

Returns a range of strike price that is calculated from delta.

=cut

sub _build_strike_price_choices {
    my $self = shift;

    my $current_spot = $self->current_spot;

    return [0.8 * $current_spot, 0.9 * $current_spot, $current_spot, 1.1 * $current_spot, 1.2 * $current_spot];
}

=head2 _build_theo_probability

Calculates the theoretical blackscholes option price (no markup)

=cut

sub _build_theo_probability {
    my $self = shift;

    $self->clear_pricing_engine;
    return $self->pricing_engine->probability;
}

=head2 theo_price

Calculates the theoretical blackscholes option price (no markup)
Difference between theo_price and theo_probability is that
theo_price is in absolute term (number, not an object)

=cut

sub theo_price {
    my $self = shift;
    return $self->theo_probability->amount;
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

    my $bid_probability = do {
        local $self->_pricing_args->{iv} = $self->pricing_vol - 0.025;
        $self->_build_theo_probability;
    };

    return $bid_probability;
}

override _build_app_markup_dollar_amount => sub {
    return 0;
};

override _build_bid_price => sub {
    my $self = shift;

    return undef if $self->pricing_new;
    return financialrounding('price', $self->currency, $self->value) if $self->is_expired;
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

override _validate_price => sub {
    my $self = shift;

    my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();
    my $ask_price     = $self->ask_price;

    if (not $ask_price or $ask_price == 0) {
        return {
            message           => 'Stake can not be zero .',
            message_to_client => [$ERROR_MAPPING->{InvalidStake}],
            details           => {field => 'amount'},
        };
    }

    # we need to allow decimal places till allowed precision for currency
    # adding 1 so that if its more thant allowed precision then it will
    # send back error
    my $currency = $self->currency;
    my $prec_num = Format::Util::Numbers::get_precision_config()->{price}->{$currency} // 0;

    my $re_num = 1 + $prec_num;

    my $ask_price_as_string = "" . $ask_price;    # Just to be sure we're dealing with a string.
    $ask_price_as_string =~ s/[\.0]+$//;          # Strip trailing zeroes and decimal points to be more friendly.

    return {
        error_code    => 'stake_too_many_places',
        error_details => [$prec_num, $ask_price],
    } if ($ask_price_as_string =~ /\.[0-9]{$re_num,}/);

    # not validating payout max as vanilla doesn't have a payout until expiry
    return undef;
};

1;
