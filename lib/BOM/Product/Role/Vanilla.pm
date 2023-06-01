package BOM::Product::Role::Vanilla;

use Moose::Role;
use Time::Duration::Concise;
use JSON::MaybeXS;
use Math::CDF qw( qnorm );

use List::Util            qw(max min);
use POSIX                 qw(ceil floor);
use Format::Util::Numbers qw/financialrounding formatnumber roundnear roundcommon/;
use BOM::Product::Static;
use BOM::Product::Contract::Strike::Vanilla;
use BOM::Config::Quants qw(minimum_stake_limit);

=head2 ADDED_CURRENCY_PRECISION

Added currency precision used in rounding number_of_contracts

=cut

use constant ADDED_CURRENCY_PRECISION => 3;

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

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

=head2 _build_min_stake

calculates minimum stake based on values from backoffice

=cut

sub _build_min_stake {
    my $self = shift;

    my $min_stake_quants = minimum_stake_limit($self->currency, $self->landing_company, $self->underlying->market->name, $self->category->code);
    my $min_stake_theoretical =
        financialrounding('price', $self->currency, $self->minimum_number_of_implied_contracts * $self->ask_probability->amount);

    my $min_stake = max($min_stake_quants, $min_stake_theoretical);

    # beautify min stake
    # different ways to process min stake depending on its value
    # values less than 1 might be crypto so we need to be careful
    if ($min_stake > 1) {
        $min_stake = ceil($min_stake);
    } else {
        # for min stake, it's okay to round up slightly
        my $precision = int(Format::Util::Numbers::get_precision_config()->{price}->{$self->currency} * 0.8);
        $min_stake = roundnear(10**-$precision, $min_stake);
    }

    # in extreme cases, min stake could be bigger than max stake
    # though it should never happen with the right BO settings
    # but adding validation here just in case
    return min($min_stake, $self->max_stake);
}

=head2 _build_max_stake

calculates maximum stake based on values from backoffice

=cut

sub _build_max_stake {
    my $self = shift;

    my $per_symbol_config      = $self->per_symbol_config();
    my $risk_profile           = $per_symbol_config->{risk_profile};
    my $max_stake_risk_profile = JSON::MaybeXS::decode_json($self->app_config->get("quants.vanilla.risk_profile.$risk_profile"))->{$self->currency};
    my $max_stake_theoretical =
        financialrounding('price', $self->currency, $self->maximum_number_of_implied_contracts() * $self->ask_probability->amount);

    my $max_stake = min($max_stake_risk_profile, $max_stake_theoretical);

    # beautify max stake
    # for example, 12.34 -> 12.00
    if ($max_stake > 1) {
        return floor($max_stake);
    } else {
        # to avoid it flickering every second, let's take 80% of the precision
        # not using roundnear as it might round the number up
        # this implementation will chop the rest of precision off
        # sprintf it to force it to be a number instead of
        # scientific notation
        my $precision = int(Format::Util::Numbers::get_precision_config()->{price}->{$self->currency} * 0.8);
        $max_stake = sprintf("%.20f", $max_stake);
        $max_stake =~ s/\.(\d{$precision}).*/.$1/;
        return $max_stake;
    }
}

=head2 _build_number_of_contracts

Calculate implied number of contracts.
n = Stake / Option Price

We need to use entry tick to calculate this figure.

=cut

sub _build_number_of_contracts {
    my $self = shift;

    my $number_of_contracts = $self->_user_input_stake / $self->initial_ask_probability->amount;
    my $currency_decimal_places =
        min(Format::Util::Numbers::get_precision_config()->{price}->{$self->currency} + ADDED_CURRENCY_PRECISION, 10);    # 10 dp is all we need
    my $rounding_precision = 10**($currency_decimal_places * -1);
    # Based on the documentation for roundcommon, this sub uses the same rounding technique as financialrounding, the only difference is that it acccepts precision
    return roundcommon($rounding_precision, $number_of_contracts);
}

=head2 per_symbol_config

Returns per symbol configuration that is configured from backoffice.
Per symbol configuration contains things like risk profile, max implied contracts per trade and etc.

=cut

sub per_symbol_config {
    my $self = shift;

    my $symbol = $self->underlying->symbol;
    my $expiry = $self->is_intraday ? 'intraday' : 'daily';

    return JSON::MaybeXS::decode_json($self->app_config->get("quants.vanilla.per_symbol_config.$symbol" . "_$expiry"));
}

=head2 minimum_number_of_implied_contracts

get minimum implied number of contracts limit from app_config (set from backoffice)

=cut

sub minimum_number_of_implied_contracts {
    my $self = shift;

    return $self->per_symbol_config()->{min_number_of_contracts}->{$self->currency};
}

=head2 maximum_number_of_implied_contracts

get maximum implied number of contracts limit from app_config (set from backoffice)

=cut

sub maximum_number_of_implied_contracts {
    my $self = shift;

    return $self->per_symbol_config()->{max_number_of_contracts}->{$self->currency};
}

=head2 maximum_number_of_strike_price

get maximum number of strike price limit from app_config (set from backoffice)

=cut

sub maximum_number_of_strike_price {
    my $self = shift;

    return $self->per_symbol_config()->{max_number_of_strike_price};
}

=head2 vol_charge

get vol markup from app_config (set from backoffice)

=cut

sub vol_charge {
    my $self = shift;

    return $self->per_symbol_config()->{vol_markup};
}

=head2 bs_markup

get black scholes price markup from app_config (set from backoffice)

=cut

sub bs_markup {
    my $self = shift;

    my $bs_markup_config = $self->per_symbol_config()->{bs_markup};

    my $markup = Math::Util::CalculatedValue->new({
        name        => 'black_scholes_markup',
        description => 'black_scholes_markup',
        set_by      => 'Contract',
        base_amount => $bs_markup_config,
    });

    return $markup;
}

=head2 strike_price_choices

calculates and return strike price choices based on delta and expiry

=cut

sub strike_price_choices {
    my $self = shift;

    my $args = {
        current_spot => $self->current_spot,
        pricing_vol  => $self->pricing_vol,
        timeinyears  => $self->timeinyears->amount,
        underlying   => $self->underlying,
        is_intraday  => $self->is_intraday
    };

    return BOM::Product::Contract::Strike::Vanilla::strike_price_choices($args);

}

=head2 base_commission

commission we charged

=cut

sub base_commission {
    my $self = shift;

    # pricing_new is more reliable than for_sale here,
    # because if pricing_new is 0,
    # client can only sell it
    return ($self->theo_probability->amount - $self->bid_probability->amount) unless $self->pricing_new;
    return ($self->ask_probability->amount - $self->theo_probability->amount);
}

=head2 _build_theo_probability

Calculates the theoretical blackscholes option price (no markup)

=cut

sub _build_theo_probability {
    my $self = shift;

    $self->clear_pricing_engine;
    my $bs_prob = $self->pricing_engine->probability;
    return $bs_prob;
}

=head2 theo_price

Calculates the theoretical blackscholes option price (no markup)
Difference between theo_price and theo_probability is that
theo_price is in absolute term (number, not an object)

=cut

override theo_price => sub {
    my $self = shift;
    return $self->theo_probability->amount;
};

=head2 initial_ask_probability

Calculates the ask probability for contract at date start.
Used in calculating number of contracts

=cut

sub initial_ask_probability {
    my $self = shift;

    my $delta_charge = $self->delta_charge;
    $delta_charge = (-$delta_charge) if $self->code eq 'VANILLALONGPUT';

    my $ask_probability = do {
        local $self->_pricing_args->{iv} = $self->pricing_vol * (1 + $self->vol_charge);

        # don't wrap them in one scope as the changes will be reverted out of scope
        local $self->_pricing_args->{spot} = $self->entry_tick->quote + $delta_charge                        unless $self->pricing_new;
        local $self->_pricing_args->{t}    = $self->calculate_timeindays_from($self->date_start)->days / 365 unless $self->pricing_new;

        $self->_build_theo_probability;
    };
    $ask_probability->include_adjustment('add', $self->bs_markup);
    return $ask_probability;
}

=head2 _build_ask_probability

Adds markup to theoretical blackscholes option price

=cut

sub _build_ask_probability {
    my $self = shift;

    my $delta_charge = $self->delta_charge;
    $delta_charge = (-$delta_charge) if $self->code eq 'VANILLALONGPUT';

    my $ask_probability = do {
        local $self->_pricing_args->{spot} = $self->current_spot + $delta_charge;
        local $self->_pricing_args->{iv}   = $self->pricing_vol * (1 + $self->vol_charge);

        # don't wrap them in one scope as the changes will be reverted out of scope
        $self->_build_theo_probability;
    };
    $ask_probability->include_adjustment('add', $self->bs_markup);
    return $ask_probability;
}

=head2 _build_bid_probability

Adds markup to theoretical blackscholes option price

=cut

sub _build_bid_probability {
    my $self = shift;

    my $delta_charge = $self->delta_charge;
    $delta_charge = (-$delta_charge) if $self->code eq 'VANILLALONGPUT';

    my $bid_probability = do {
        local $self->_pricing_args->{spot} = $self->current_spot - $delta_charge;
        local $self->_pricing_args->{iv}   = $self->pricing_vol * (1 - $self->vol_charge);
        $self->_build_theo_probability;
    };
    $bid_probability->include_adjustment('subtract', $self->bs_markup);
    return $bid_probability;
}

=head2 buy_commission

Commission for affiliate when client buys contract

=cut

sub buy_commission {
    my $self = shift;

    # buy commission = stake * (ask_0 - mid)/ask_0
    #                = number of contracts * (ask_0 - mid)
    return $self->number_of_contracts * ($self->initial_ask_probability->amount - $self->theo_probability->amount);
}

=head2 sell_commission

Commission for affiliate when client sells contract

=cut

sub sell_commission {
    my $self = shift;

    # sell commission = stake * (mid - bid)/ask_0
    #                 = number of contracts * (mid - bid)

    # no commission charged when contract is left until expiry
    return 0 if $self->is_expired;
    return $self->number_of_contracts * ($self->theo_probability->amount - $self->bid_probability->amount);
}

=head2 delta_charge

Delta charge on vanilla options.
Values (spread_spot) come from backoffice

=cut

sub delta_charge {
    my $self = shift;

    my $spread_spot = $self->per_symbol_config()->{spread_spot};
    $spread_spot = abs($self->delta) * $spread_spot / 2;

    return $spread_spot;
}

=head2 _validate_stake

validate maximum stake based on financial underlying risk profile defined in backoffice

=cut

sub _validate_stake {
    my $self = shift;

    if ($self->_user_input_stake > $self->max_stake) {
        return {
            message           => 'maximum stake limit',
            message_to_client => [$ERROR_MAPPING->{StakeLimitExceeded}, financialrounding('price', $self->currency, $self->max_stake)],
            details           => {
                field           => 'amount',
                min_stake       => $self->min_stake,
                max_stake       => $self->max_stake,
                barrier_choices => $self->strike_price_choices
            },
        };
    }

    # facing weird issues where stake < min_stake being evaluated as true
    # when they are equal, so we need to check if they are different or not
    if ($self->_user_input_stake ne $self->min_stake) {
        if ($self->_user_input_stake < $self->min_stake) {
            return {
                message           => 'minimum stake limit exceeded',
                message_to_client => [$ERROR_MAPPING->{InvalidMinStake}, financialrounding('price', $self->currency, $self->min_stake)],
                details           => {
                    field           => 'amount',
                    min_stake       => $self->min_stake,
                    max_stake       => $self->max_stake,
                    barrier_choices => $self->strike_price_choices
                },
            };
        }
    }
}

=head2 _validation_methods

all validation methods needed for vanilla

=cut

sub _validation_methods {
    my $self = shift;

    my @validation_methods = qw(_validate_offerings _validate_input_parameters _validate_start_and_expiry_date);
    push @validation_methods, qw(_validate_trading_times) unless $self->underlying->always_available;
    push @validation_methods, '_validate_barrier_type'    unless $self->for_sale;
    push @validation_methods, '_validate_feed';
    push @validation_methods, '_validate_price'      unless $self->skips_price_validation;
    push @validation_methods, '_validate_volsurface' unless $self->underlying->volatility_surface_type eq 'flat';
    push @validation_methods, '_validate_rollover_blackout';

    # add vanilla specific validations
    push @validation_methods, '_validate_barrier_choice' unless $self->for_sale;
    push @validation_methods, '_validate_stake'          unless $self->for_sale;

    return \@validation_methods;
}

override _build_app_markup_dollar_amount => sub {
    return 0;
};

override _build_bid_price => sub {
    my $self = shift;

    return financialrounding('price', $self->currency, $self->value) if $self->is_expired;
    return financialrounding('price', $self->currency, $self->_build_bid_probability->amount * $self->number_of_contracts);
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

=head2 _validate_barrier_choice

validate barrier chosen by user, validation will fail if it's not the barrier choice that we offer

=cut

sub _validate_barrier_choice {
    my $self = shift;

    my $strike_price_choices = $self->strike_price_choices;

    foreach my $strike (@{$strike_price_choices}) {
        if ($self->supplied_barrier eq $strike) {
            return;
        }
    }

    my $message = "Barriers available are " . join(", ", @{$strike_price_choices});

    return {
        message           => 'InvalidBarrier',
        message_to_client => [$message],
        details           => {
            field           => 'barrier',
            min_stake       => $self->min_stake,
            max_stake       => $self->max_stake,
            barrier_choices => $strike_price_choices
        },
    };
}

override _validate_price => sub {
    my $self = shift;

    my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();
    my $ask_price     = $self->ask_price;

    if (not $ask_price or $ask_price == 0) {
        return {
            message           => 'Stake can not be zero .',
            message_to_client => [$ERROR_MAPPING->{InvalidMinStake}, financialrounding('price', $self->currency, $self->min_stake)],
            details           => {
                field           => 'amount',
                min_stake       => $self->min_stake,
                max_stake       => $self->max_stake,
                barrier_choices => $self->strike_price_choices
            },
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
