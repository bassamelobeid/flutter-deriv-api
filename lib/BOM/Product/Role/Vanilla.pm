package BOM::Product::Role::Vanilla;

use Moose::Role;
use Time::Duration::Concise;
use JSON::MaybeXS;
use Math::CDF qw( qnorm );

use List::Util            qw(max min);
use List::MoreUtils       qw(any);
use POSIX                 qw(ceil floor);
use Format::Util::Numbers qw/financialrounding formatnumber roundnear roundcommon/;
use BOM::Product::Static;
use BOM::Product::Contract::Strike::Vanilla;
use BOM::Product::Utils qw(business_days_between weeks_between);
use Math::Util::CalculatedValue;
use Syntax::Keyword::Try;
use BOM::Config::Quants qw(minimum_stake_limit);
use Quant::Framework::Spread::InterpolatedSpread;
use Machine::Epsilon;

=head2 ADDED_CURRENCY_PRECISION

Added currency precision used in rounding number_of_contracts

=cut

=head2 SETTLEMENT_TIME

settlement time for vanilla financials

=cut

use constant ADDED_CURRENCY_PRECISION => 3;
use constant {SETTLEMENT_TIME => '10:00:00'};

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

=head2 BUILD

This method is mainly to override date_expiry if market is not synthetic indices

=cut

sub BUILD {
    my $self = shift;

    unless ($self->is_synthetic) {
        my $nyt_offset  = $self->date_expiry->timezone_offset('America/New_York');
        my $date_expiry = $self->date_expiry;
        $self->date_expiry(Date::Utility->new($date_expiry->date_yyyymmdd . ' ' . SETTLEMENT_TIME)->minus_time_interval($nyt_offset));
    }

}

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

=head2 is_synthetic

return 1 if underlying is synthetic indices (independent indices)

=cut

sub is_synthetic {
    my $self = shift;

    return ($self->underlying->market->name eq 'synthetic_index');
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

has spread_calculator => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_spread_calculator',
);

=head2 _build_spread_calculator

returns a Quant::Framework::Spread::InterpolatedSpread object

=cut

sub _build_spread_calculator {
    my $self = shift;

    return Quant::Framework::Spread::InterpolatedSpread->new({
        date_start    => $self->date_start,
        custom_spread =>
            JSON::MaybeXS::decode_json($self->app_config->get('quants.vanilla.fx_spread_specific_time'))->{$self->underlying->symbol},
        spread_spot              => $self->per_symbol_config()->{spread_spot},
        spread_vol               => $self->per_symbol_config()->{spread_vol},
        maturities_allowed_days  => $self->per_symbol_config()->{maturities_allowed_days},
        maturities_allowed_weeks => $self->per_symbol_config()->{maturities_allowed_weeks},
    });

}

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

    # if the probability is negligibly small return an error
    my $epsilon = machine_epsilon();
    if (abs($self->initial_ask_probability->amount) < $epsilon) {
        BOM::Product::Exception->throw(
            error_code => 'InvalidNonBinaryPrice',
        );
    }

    # we want payout per pip for financials
    my $number_of_contracts     = $self->_user_input_stake / $self->initial_ask_probability->amount;
    my $currency_decimal_places = Format::Util::Numbers::get_precision_config()->{price}->{$self->currency} + ADDED_CURRENCY_PRECISION;
    my $rounding_precision      = 10**($currency_decimal_places * -1);
    # Based on the documentation for roundcommon, this sub uses the same rounding technique as financialrounding, the only difference is that it acccepts precision
    $number_of_contracts = roundcommon($rounding_precision, $number_of_contracts);
    return $number_of_contracts if $self->is_synthetic;
    return roundcommon($rounding_precision, $number_of_contracts * $self->underlying->pip_size);

}

=head2 per_symbol_config

Returns per symbol configuration that is configured from backoffice.
Per symbol configuration contains things like risk profile, max implied contracts per trade and etc.

=cut

sub per_symbol_config {
    my $self = shift;

    my $symbol = $self->underlying->symbol;
    my $expiry = $self->is_intraday ? 'intraday' : 'daily';

    return JSON::MaybeXS::decode_json($self->app_config->get("quants.vanilla.fx_per_symbol_config.$symbol")) unless $self->is_synthetic;
    return JSON::MaybeXS::decode_json($self->app_config->get("quants.vanilla.per_symbol_config.$symbol" . "_$expiry"));
}

=head2 get_tenor

Returns tenor of the contract in form of number and unit (days and weeks).
For example, '5D', '3W'

=cut

sub get_tenor {
    my $self = shift;

    my $per_symbol_config     = $self->per_symbol_config();
    my $nyt_offset            = $self->date_expiry->timezone_offset('America/New_York');
    my $nyt                   = $self->date_expiry->plus_time_interval($nyt_offset);
    my $business_days_between = business_days_between($self->date_start, $nyt, $self->underlying);
    my $weeks_between         = weeks_between($self->date_start, $nyt);

    my $maturity;

    if (any { $_ eq $business_days_between } $per_symbol_config->{maturities_allowed_days}->@*) {
        $maturity = $business_days_between . "D";
    } elsif (any { $_ eq $weeks_between } $per_symbol_config->{maturities_allowed_weeks}->@*) {
        $maturity = $weeks_between . "W";
    } else {
        # expiry is not offered, to avoid logs, we will use the maximum maturity in weeks
        $maturity = max $per_symbol_config->{maturities_allowed_weeks}->@*;
    }

    return $maturity;

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

    return 0 unless $self->is_synthetic;
    return $self->per_symbol_config()->{vol_markup};
}

=head2 get_strike_price_offering_and_markup

get strike price offering and markup from app_config (set from backoffice)
returns a hash if markup is found, otherwise returns undef

=cut

sub get_strike_price_offering_and_markup {
    my $self = shift;

    my $strike_price_range_markup = $self->app_config->get("quants.vanilla.strike_price_range_markup");
    # since daily contract ends at 23:59:59, it's possible that t is slightly bigger than 1
    my $time_to_expiry = min(1, $self->timeinyears->amount);

    if ($strike_price_range_markup) {
        $strike_price_range_markup = JSON::MaybeXS::decode_json($strike_price_range_markup);
        if (my $markup_config = $strike_price_range_markup->{$self->underlying->symbol}) {
            for my $entry_id (keys $markup_config->%*) {
                my $entry              = $markup_config->{$entry_id};
                my $strike_price_range = $entry->{strike_price_range};
                my $duration_range     = $entry->{contract_duration};
                my $barrier            = $self->barrier->as_absolute;

                # apply markup if barrier is between min and max strike price
                # and between min and max duration
                if (    ($barrier >= $strike_price_range->{min})
                    and ($barrier <= $strike_price_range->{max})
                    and ($time_to_expiry >= $duration_range->{min})
                    and ($time_to_expiry <= $duration_range->{max})
                    and ($self->code eq $entry->{trade_type}))
                {

                    return {
                        disable_offering => $entry->{disable_offering},
                        markup           => $entry->{markup}};
                }

            }
        }
    }

    return undef;
}

=head2 bs_markup

get black scholes price markup from app_config (set from backoffice)

=cut

sub bs_markup {
    my $self = shift;

    my $bs_markup_config = $self->per_symbol_config()->{bs_markup};

    my $bs_markup = Math::Util::CalculatedValue->new({
        name        => 'black_scholes_markup',
        description => 'black_scholes_markup',
        set_by      => 'Contract',
        base_amount => $bs_markup_config,
    });

    # since we can't short
    # only apply this markup
    # during buy
    unless ($self->for_sale) {
        if (my $offering_and_markup = $self->get_strike_price_offering_and_markup) {
            my $extra_markup = Math::Util::CalculatedValue->new({
                name        => 'extra black_scholes_markup',
                description => 'extra black_scholes_markup',
                set_by      => 'Contract',
                base_amount => $offering_and_markup->{markup},
            });
            $bs_markup->include_adjustment('add', $extra_markup) unless $offering_and_markup->{disable_offering};
        }
    }

    return $bs_markup;
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
        is_intraday  => $self->is_intraday,
        trade_type   => $self->code
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
    return $self->number_of_contracts * ($self->theo_probability->amount - $self->bid_probability->amount) unless $self->pricing_new;
    return $self->number_of_contracts * ($self->ask_probability->amount - $self->theo_probability->amount);
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

has close_tick => (
    is         => 'ro',
    lazy_build => 1
);

=head2 _build_close_tick

Approximates the sold at market tick.
Given sell price,
we can calculate bid price at sell time and sell time - 1.
The tick with smaller difference between bid price and sell price is the sold at market tick.

=cut

sub _build_close_tick {
    my $self = shift;

    my $sell_price = $self->sell_price;
    return unless $sell_price;

    my $tick_at_sell_time = $self->_tick_accessor->tick_at($self->sell_time,     {allow_inconsistent => 1});
    my $tick_before_that  = $self->_tick_accessor->tick_at($self->sell_time - 1, {allow_inconsistent => 1});

    my $bid_price_at_sell_time = do {
        local $self->_pricing_args->{spot} = $tick_at_sell_time->quote;
        $self->_build_bid_probability;
    };

    my $bid_price_before_that = do {
        local $self->_pricing_args->{spot} = $tick_before_that->quote;
        $self->_build_bid_probability;
    };

    my $number_of_contracts = $self->number_of_contracts;
    $number_of_contracts = $number_of_contracts / $self->underlying->pip_size unless $self->is_synthetic;

    $bid_price_at_sell_time = $bid_price_at_sell_time->amount * $number_of_contracts;
    $bid_price_before_that  = $bid_price_before_that->amount * $number_of_contracts;

    return abs($sell_price - $bid_price_at_sell_time) < abs($sell_price - $bid_price_before_that) ? $tick_at_sell_time : $tick_before_that;

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

=head2 max_duration

maximum duration (in days) offered for vanilla options on financials

=cut

sub max_duration {
    my $self = shift;

    return {
        duration      => 365,
        duration_unit => 'd'
    } if $self->is_synthetic;

    my $per_symbol_config = $self->per_symbol_config();

    my @maturities_allowed_days  = @{$per_symbol_config->{maturities_allowed_days}};
    my @maturities_allowed_weeks = @{$per_symbol_config->{maturities_allowed_weeks}};

    my $max_day  = max @maturities_allowed_days;
    my $max_week = max @maturities_allowed_weeks;

    # there are 7 days in a week
    return {
        duration      => max($max_day, $max_week * 7),
        duration_unit => 'd'
    };
}

=head2 spread

Calculate commission for vanilla options.
- Returns no spread if underlying is synthetic
- Returns specific spread if we have specific spread for this contract
- Returns interpolated spread if none of the above

Returns a Math::Util::CalculatedValue object

=cut

sub spread {
    my $self = shift;

    return Math::Util::CalculatedValue->new({
            name        => 'spread',
            description => 'vanilla options commission spread',
            set_by      => 'Contract',
            base_amount => 0
        }) if $self->is_synthetic;    # only applicable to financial offerings

    # difference between t and tenor
    # t = 1/365
    # tenor = 1D
    return Math::Util::CalculatedValue->new({
            name        => 'spread',
            description => 'vanilla options commission spread',
            set_by      => 'Contract',
            base_amount => $self->spread_calculator->get_spread({
                    delta => abs($self->delta),
                    vega  => $self->vega,
                    t     => $self->timeinyears->amount,
                    tenor => $self->get_tenor
                })});
}

=head2 initial_ask_probability

Calculates the ask probability for contract at date start.
Used in calculating number of contracts

=cut

sub initial_ask_probability {
    my $self = shift;

    my $ask_probability = do {
        local $self->_pricing_args->{iv} = $self->pricing_vol * (1 + $self->vol_charge);

        # don't wrap them in one scope as the changes will be reverted out of scope
        local $self->_pricing_args->{spot} = $self->entry_spot                                               unless $self->pricing_new;
        local $self->_pricing_args->{t}    = $self->calculate_timeindays_from($self->date_start)->days / 365 unless $self->pricing_new;

        $self->_build_theo_probability;
    };

    $ask_probability->include_adjustment('add', $self->spread);
    $ask_probability->include_adjustment('add', $self->delta_charge);
    $ask_probability->include_adjustment('add', $self->bs_markup);
    return $ask_probability;
}

=head2 _build_ask_probability

Adds markup to theoretical blackscholes option price

=cut

sub _build_ask_probability {
    my $self = shift;

    my $ask_probability = do {
        local $self->_pricing_args->{iv} = $self->pricing_vol * (1 + $self->vol_charge);

        # don't wrap them in one scope as the changes will be reverted out of scope
        $self->_build_theo_probability;
    };

    $ask_probability->include_adjustment('add', $self->spread);
    $ask_probability->include_adjustment('add', $self->delta_charge);
    $ask_probability->include_adjustment('add', $self->bs_markup);
    return $ask_probability;
}

=head2 _build_bid_probability

Adds markup to theoretical blackscholes option price

=cut

sub _build_bid_probability {
    my $self = shift;

    my $bid_probability = do {
        local $self->_pricing_args->{iv} = $self->pricing_vol * (1 - $self->vol_charge);
        $self->_build_theo_probability;
    };

    $bid_probability->include_adjustment('subtract', $self->spread);
    $bid_probability->include_adjustment('subtract', $self->delta_charge);
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

    my $spread_spot = 0;
    $spread_spot = $self->per_symbol_config()->{spread_spot} if $self->is_synthetic;
    $spread_spot = abs($self->delta) * $spread_spot / 2;

    my $markup = Math::Util::CalculatedValue->new({
        name        => 'delta_charge',
        description => 'delta_charge',
        set_by      => 'Contract',
        base_amount => $spread_spot,
    });

    return $markup;
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
    push @validation_methods, '_validate_price_non_binary' unless $self->skips_price_validation;
    push @validation_methods, '_validate_volsurface'       unless $self->underlying->volatility_surface_type eq 'flat';
    push @validation_methods, '_validate_rollover_blackout';

    # add vanilla specific validations
    push @validation_methods, '_validate_expiry'         unless $self->is_synthetic;
    push @validation_methods, '_validate_barrier_choice' unless $self->for_sale;
    push @validation_methods, '_validate_stake'          unless $self->for_sale;
    return \@validation_methods;
}

override _build_app_markup_dollar_amount => sub {
    return 0;
};

override _build_bid_price => sub {
    my $self = shift;

    my $number_of_contracts = $self->number_of_contracts;
    # we need to adjust payout per pip back to number of contracts for financials
    $number_of_contracts = $number_of_contracts / $self->underlying->pip_size unless $self->is_synthetic;

    return financialrounding('price', $self->currency, $self->value) if $self->is_expired;
    return financialrounding('price', $self->currency, $self->_build_bid_probability->amount * $number_of_contracts);
};

override '_build_ask_price' => sub {
    my $self = shift;
    return $self->_user_input_stake;
};

override 'shortcode' => sub {
    my $self = shift;

    # these 2 attributes are extremely sensitive to time
    # hence placing them near each other
    my $entry_tick          = $self->entry_tick;
    my $number_of_contracts = $self->number_of_contracts;
    return join '_',
        (
        uc $self->code,
        uc $self->underlying->symbol,
        financialrounding('price', $self->currency, $self->_user_input_stake),
        $self->date_start->epoch,
        $self->date_expiry->epoch,
        $self->_barrier_for_shortcode_string($self->supplied_barrier),
        $number_of_contracts, $entry_tick->epoch
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

    my $entry_epoch_from_shortcode = $self->build_parameters->{entry_epoch};

    return $self->_tick_accessor->tick_at($entry_epoch_from_shortcode) if $entry_epoch_from_shortcode;

    return $self->_tick_accessor->tick_at($self->date_start->epoch, {allow_inconsistent => 1});
};

=head2 _validate_barrier_choice

validate barrier chosen by user, validation will fail if it's not the barrier choice that we offer

=cut

sub _validate_barrier_choice {
    my $self = shift;

    my $strike_price_choices = $self->strike_price_choices;

    if (my $offering_and_markup = $self->get_strike_price_offering_and_markup) {
        if ($offering_and_markup->{disable_offering}) {
            return {
                message           => 'BarrierOutOfRange',
                message_to_client => ['Barrier is out of acceptable range. Please choose another barrier or the opposite contract type.'],
                details           => {
                    field           => 'barrier',
                    min_stake       => $self->min_stake,
                    max_stake       => $self->max_stake,
                    barrier_choices => $strike_price_choices
                },
            };
        }

    }

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

=head2 _validate_expiry

For vanilla financials, we only expire on 10am NYT and only specific durations are offered.
This subroutine is to validate the expiry date and time.

=cut

sub _validate_expiry {
    my $self = shift;

    my $nyt_offset = $self->date_expiry->timezone_offset('America/New_York');
    my $nyt        = $self->date_expiry->plus_time_interval($nyt_offset);

    my $symbol = $self->underlying->symbol;
    my @maturities_allowed_days =
        @{JSON::MaybeXS::decode_json($self->app_config->get("quants.vanilla.fx_per_symbol_config.$symbol"))->{maturities_allowed_days}};
    my @maturities_allowed_weeks =
        @{JSON::MaybeXS::decode_json($self->app_config->get("quants.vanilla.fx_per_symbol_config.$symbol"))->{maturities_allowed_weeks}};

    return {
        message           => 'InvalidExpiry',
        message_to_client => ['Contract cannot end at same day'],
        details           => {
            field           => 'amount',
            min_stake       => $self->min_stake,
            max_stake       => $self->max_stake,
            barrier_choices => $self->strike_price_choices
        },
        }
        if ($self->date_expiry->date eq $self->date_start->date);

    # early return if it's not 10am NYT
    return {
        message           => 'InvalidExpiry',
        message_to_client => ['Contract must end at 10:00 am New York Time'],
        details           => {
            field           => 'amount',
            min_stake       => $self->min_stake,
            max_stake       => $self->max_stake,
            barrier_choices => $self->strike_price_choices
        },
        }
        if ($nyt->time_hhmmss ne SETTLEMENT_TIME);

    my $business_days_between = business_days_between($self->date_start, $nyt, $self->underlying);
    my $weeks_between         = weeks_between($self->date_start, $nyt);
    if (   (any { $_ eq $business_days_between } @maturities_allowed_days)
        or (any { $_ eq $weeks_between } @maturities_allowed_weeks))
    {

        return {
            message           => 'InvalidExpiry',
            message_to_client => ['Contract more than 1 week must end on Friday'],
            details           => {
                field           => 'amount',
                min_stake       => $self->min_stake,
                max_stake       => $self->max_stake,
                barrier_choices => $self->strike_price_choices
            },
            }
            if (($nyt->full_day_name ne 'Friday')
            and ($nyt->time_hhmmss eq SETTLEMENT_TIME)
            and ($business_days_between >= 7));

        return;
    } else {
        return {
            message           => 'InvalidExpiry',
            message_to_client => [
                "Invalid contract duration. Durations offered are (@maturities_allowed_days) days and every Friday after (@maturities_allowed_weeks) weeks."
            ],
            details => {
                field           => 'amount',
                min_stake       => $self->min_stake,
                max_stake       => $self->max_stake,
                barrier_choices => $self->strike_price_choices
            },
        };
    }

}

1;
