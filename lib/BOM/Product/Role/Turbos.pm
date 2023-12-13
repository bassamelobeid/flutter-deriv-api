package BOM::Product::Role::Turbos;

use Moose::Role;
use Time::Duration::Concise;
use Format::Util::Numbers qw/financialrounding roundcommon/;
use Scalar::Util::Numeric qw(isint);
use List::Util            qw/min max/;
use YAML::XS              qw(LoadFile);
use POSIX                 qw(ceil floor);

use BOM::Config::Redis;
use BOM::Product::Exception;
use BOM::Product::Static;
use BOM::Product::Contract::Strike::Turbos;
use BOM::Config::Quants qw(minimum_stake_limit);
with 'BOM::Product::Role::AmericanExpiry' => {-excludes => ['_build_hit_tick', '_build_close_tick']};
with 'BOM::Product::Role::SingleBarrier'  => {-excludes => '_validate_barrier'};

=head2 ADDED_CURRENCY_PRECISION

Added currency precision used in rounding number_of_contracts

=cut

use constant ADDED_CURRENCY_PRECISION => 3;

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

=head2 quants_config

QuantsConfig object attribute

=head2 per_symbol_config

Returns per symbol configuration that is configured from backoffice.

=head2 fixed_config

Returns fixed configurations that can't be changed from backoffice.
which are sigma, average_tick_size_up, and average_tick_size_down

=cut

has [qw(quants_config per_symbol_config fixed_config)] => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 _build_quants_config

Builds a QuantsConfig object

=cut

sub _build_quants_config {
    my $self = shift;

    my $qc = BOM::Config::QuantsConfig->new(
        contract_category => $self->category_code,
        for_date          => $self->date_start,
        chronicle_reader  => BOM::Config::Chronicle::get_chronicle_reader($self->date_start));

    return $qc;
}

=head2 _build_per_symbol_config

initialize per_symbol_config

=cut

sub _build_per_symbol_config {
    my $self = shift;

    my $config = $self->quants_config->get_per_symbol_config({
        underlying_symbol => $self->underlying->symbol,
        need_latest_cache => 1
    });

    return $config if $config && %$config;

    $self->_add_error({
        message           => 'turbos config undefined for ' . $self->underlying->symbol,
        message_to_client => $ERROR_MAPPING->{InvalidInputAsset},
    });
}

=head2 _build_fixed_config 

initialize fixed_config

=cut

sub _build_fixed_config {
    return LoadFile('/home/git/regentmarkets/bom-config/share/fixed_turbos_config.yml');
}

has [qw(per_symbol_config fixed_config)] => (
    is         => 'ro',
    lazy_build => 1,
);

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

=head2 _redis_read

Redis read from Replica instance

=cut

=head2 _redis_write

Redis write instance

=cut

has [qw(_redis_read _redis_write)] => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 _build__redis_read

Returns a Redis read Replica instance

=cut

sub _build__redis_read {

    return BOM::Config::Redis::redis_replicated_read();
}

=head2 _build__redis_write

Returns a Redis write instance

=cut

sub _build__redis_write {

    return BOM::Config::Redis::redis_replicated_write();
}

=head2 take_profit

Take profit amount. Contract will be closed automatically when the value of open position is at or greater than take profit amount.

=cut

has take_profit => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 _build_take_profit

Take profit amount. Contract will be closed automatically when the value of open position is at or greater than take profit amount.

=cut

sub _build_take_profit {
    my $self = shift;

    if ($self->pricing_new and defined $self->_order->{take_profit}) {
        return {
            amount => $self->_order->{take_profit},
            date   => $self->date_pricing,
        };
    }

    if (defined $self->_order->{take_profit}{order_date}) {
        return {
            amount => $self->_order->{take_profit}{order_amount},
            date   => Date::Utility->new($self->_order->{take_profit}{order_date}),
        };
    }

    return;
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

has [qw(number_of_contracts n_max)] => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 _build_n_max

Maximum number of contracts. For barrier choices calculation

=cut

sub _build_n_max {
    my $self = shift;

    my $max_multiplier_stake = $self->per_symbol_config->{max_multiplier_stake}{$self->currency};
    my $max_multiplier       = $self->per_symbol_config->{max_multiplier};

    unless (defined $max_multiplier_stake && defined $max_multiplier) {
        BOM::Product::Exception->throw(error_code => 'MissingRequiredContractConfig');
    }

    return $max_multiplier_stake * $max_multiplier / $self->current_spot if $self->pricing_new;
    return $max_multiplier_stake * $max_multiplier / $self->entry_tick->quote;

}

=head2 theo_ask_probability

Calculates the theoretical blackscholes option price (no markup)

=cut

sub theo_ask_probability {
    my ($self, $tick) = @_;

    $tick //= $self->entry_tick;

    my $ask_price = $tick->quote * (1 + $self->ask_spread);

    return $ask_price;
}

=head2 theo_bid_probability

Calculates the theoretical blackscholes option price (no markup)

=cut

sub theo_bid_probability {
    my ($self, $tick) = @_;

    $tick //= $self->entry_tick;
    my $bid_price = $tick->quote * (1 - $self->bid_spread);

    return $bid_price;
}

=head2 bid_spread

spread charged on contract close

=head2 ask_spread

spread charged on contract purchase

=cut

has [qw(bid_spread ask_spread)] => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 _build_bid_spread

build spread charged on contract close

=cut

sub _build_bid_spread {
    my $self = shift;

    my $expiry                = $self->expiry_type;
    my $symbol                = $self->underlying->symbol;
    my $ticks_commission_down = $self->per_symbol_config->{"ticks_commission_down_${expiry}"};
    my $avg_tick_size_down    = $self->fixed_config->{$symbol} ? $self->fixed_config->{$symbol}{average_tick_size_down} : undef;

    unless (defined $avg_tick_size_down && defined $ticks_commission_down) {
        BOM::Product::Exception->throw(error_code => 'MissingRequiredContractConfig');
    }

    return $avg_tick_size_down * $ticks_commission_down;
}

=head2 _build_ask_spread

build spread charged on contract purchase

=cut

sub _build_ask_spread {
    my $self = shift;

    my $expiry              = $self->expiry_type;
    my $symbol              = $self->underlying->symbol;
    my $ticks_commission_up = $self->per_symbol_config->{"ticks_commission_up_${expiry}"};
    my $avg_tick_size_up    = $self->fixed_config->{$symbol} ? $self->fixed_config->{$symbol}{average_tick_size_up} : undef;

    unless (defined $avg_tick_size_up && defined $ticks_commission_up) {
        BOM::Product::Exception->throw(error_code => 'MissingRequiredContractConfig');
    }

    return $avg_tick_size_up * $ticks_commission_up;
}

=head2 buy_commission

commission charged when client enters a contract

=cut

sub buy_commission {
    my $self = shift;

    return $self->number_of_contracts * $self->current_spot * $self->ask_spread;
}

=head2 sell_commission

commission charged when client sells a contract. this value is charged only when the contract is not expired yet. 

=cut

sub sell_commission {
    my $self = shift;

    return 0 if $self->is_expired;
    return $self->number_of_contracts * $self->current_spot * $self->bid_spread;
}

=head2 base_commission

commission charged on buy or sell. This value is used in calculating allowed_slippage. 

=cut

sub base_commission {
    my $self = shift;

    # No need for slippage validation on buy
    return 0 if $self->pricing_new;
    return $self->sell_commission;
}

=head2 _build_number_of_contracts

Calculate implied number of contracts.
n = Stake / Option Price
We need to use entry tick to calculate this figure.

=cut

sub _build_number_of_contracts {
    my $self = shift;

    my $contract_price = $self->_contract_price;

    my $number_of_contracts = $contract_price ? ($self->_user_input_stake / $contract_price) : $self->_contracts_limit->{min};

    my $currency_decimal_places = Format::Util::Numbers::get_precision_config()->{price}->{$self->currency} + ADDED_CURRENCY_PRECISION;
    my $rounding_precision      = 10**($currency_decimal_places * -1);
    # Based on the documentation for roundcommon, this sub uses the same rounding technique as financialrounding, the only difference is that it acccepts precision
    return roundcommon($rounding_precision, $number_of_contracts);
}

=head2 available_orders

Shows the most recent limit orders for a contract.

This is formatted in a way that it can be directly put into PRICER_ARGS.

=cut

sub available_orders {
    my $self = shift;

    my @available_orders = ();

    if ($self->take_profit) {
        push @available_orders, ('take_profit', ['order_amount', $self->take_profit->{amount}, 'order_date', $self->take_profit->{date}->epoch]);
    }

    return \@available_orders;
}

=head2 _contracts_limit

The minimum and maximum number of contracts for a specifc symbol.

=cut

has _contracts_limit => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 _build__contracts_limit

The minimum and maximum number of contracts for a specifc symbol.

=cut

sub _build__contracts_limit {
    my $self = shift;

    my $currency             = $self->currency;
    my $max_multiplier       = $self->per_symbol_config->{max_multiplier};
    my $max_multiplier_stake = $self->per_symbol_config->{max_multiplier_stake}{$currency};
    my $min_multiplier       = $self->per_symbol_config->{min_multiplier};
    my $min_multiplier_stake = $self->per_symbol_config->{min_multiplier_stake}{$currency};

    unless (defined $max_multiplier and defined $max_multiplier_stake and defined $min_multiplier and defined $min_multiplier_stake) {
        BOM::Product::Exception->throw(error_code => 'MissingRequiredContractConfig');
    }

    my $max = $max_multiplier * $max_multiplier_stake / $self->entry_tick->quote;
    my $min = $min_multiplier * $min_multiplier_stake / $self->entry_tick->quote;

    return {
        min => $min,
        max => $max,
    };
}

override _build_app_markup_dollar_amount => sub {
    return 0;
};

=head2 bid_price

Bid price which will be saved into sell_price in financial_market_bet table.

=cut

override '_build_bid_price' => sub {
    my $self = shift;

    my $bid_price = $self->is_sold ? $self->sell_price : $self->is_expired ? $self->value : $self->calculate_payout;
    # bid price should not be negative because the maximum loss for the client is the stake.
    $bid_price = max(0, $bid_price);

    return financialrounding('price', $self->currency, $bid_price);
};

override '_build_ask_price' => sub {
    my $self = shift;
    return $self->_user_input_stake;
};

=head2 _build_close_tick

Returns the tick at sell time. We don't store the tick information at contract sell time in the contract database.
Due to race condition between new tick arrival and the sell action, the sell tick could be:
- tick at sell time
- previous tick at sell time.

To fetch the correct tick, we recalculate the value of the contract at sell time. This is slightly trickier
than other contract types because of the commission model. We only charge commission when:
- client sell the contract back to us before the contract expiration
- contract is sold by expiry daemon when it hits take profit

=cut

sub _build_close_tick {
    my $self = shift;

    my $sell_price = $self->sell_price;

    # Contract is closed because of hitting take profit or barrier
    return $self->hit_tick if $self->hit_tick;

    # Close tick for tick expiry duration will be undefined because there's no option to sell back early.
    # tick_expiry is 1 for duration tick contract by default
    return undef if $self->tick_expiry;

    # If there's no sell price, the contract is still open.
    # close_tick should be undefined.
    return undef unless $sell_price;

    my $exit_tick = $self->exit_tick;

    # Contract - right at the date_expiry and contract is not sold yet
    return $exit_tick if $exit_tick and not $self->is_sold;

    # Contract that is sold at expiry time
    return $exit_tick if ($self->sell_time >= $self->date_expiry->epoch);

    # If the contract is sold early, the close tick could either be tick at sell time or one tick before that.
    # We do that buy recalculating the sell price
    my $tick_at_sell_time = $self->_tick_accessor->tick_at($self->sell_time,     {allow_inconsistent => 1});
    my $tick_before_that  = $self->_tick_accessor->tick_at($self->sell_time - 1, {allow_inconsistent => 1});

    my $bid_price_at_sell_time = $self->calculate_payout($tick_at_sell_time);
    my $bid_price_before_that  = $self->calculate_payout($tick_before_that);

    return abs($sell_price - $bid_price_at_sell_time) <= abs($sell_price - $bid_price_before_that) ? $tick_at_sell_time : $tick_before_that;

}

has [qw(min_stake max_stake)] => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 _build_min_stake

get current min stake

=cut

sub _build_min_stake {
    my $self = shift;

    my $min_default_stake = minimum_stake_limit(($self->currency, $self->landing_company, $self->underlying->market->name, 'turbos'));
    my $distance          = abs($self->entry_tick->quote - $self->barrier->as_absolute);
    my $min_stake         = max($min_default_stake, $self->_contracts_limit->{min} * $distance);

    # if min_stake > max_stake happens we lessen the min_stake to max_stake
    $min_stake = min($min_stake, $self->max_stake);

    return financialrounding('price', $self->currency, $min_stake);
}

=head2 _build_max_stake

get current max stake

=cut

sub _build_max_stake {
    my $self = shift;

    my $distance                   = abs($self->entry_tick->quote - $self->barrier->as_absolute);
    my $max_stake                  = $self->_contracts_limit->{max} * $distance;
    my $max_stake_per_risk_profile = $self->quants_config->get_max_stake_per_risk_profile($self->risk_level);

    return min(financialrounding('price', $self->currency, $max_stake), $max_stake_per_risk_profile->{$self->currency});
}

=head2 risk_level

Defines the risk_level per_symbol or per_market

=cut

sub risk_level {
    my $self = shift;

    my $risk_profile_per_symbol = $self->quants_config->get_risk_profile_per_symbol;
    my $risk_profile_per_market = $self->quants_config->get_risk_profile_per_market;
    my $symbol                  = $self->underlying->symbol;
    my $market                  = $self->market;

    return $risk_profile_per_symbol->{$symbol}       if ($risk_profile_per_symbol and $risk_profile_per_symbol->{$symbol});
    return $risk_profile_per_market->{$market->name} if ($risk_profile_per_market and $risk_profile_per_market->{$market->name});
    return $market->{risk_profile};

}

override 'shortcode' => sub {
    my $self = shift;

    my $shortcode_date_expiry =
        ($self->tick_expiry)
        ? $self->tick_count . 'T'
        : $self->date_expiry->epoch;

    return join '_',
        (
        uc $self->code,                                                        uc $self->underlying->symbol,
        financialrounding('price', $self->currency, $self->_user_input_stake), $self->date_start->epoch,
        $shortcode_date_expiry,                                                $self->_barrier_for_shortcode_string($self->supplied_barrier),
        $self->number_of_contracts,                                            $self->entry_tick->epoch
        );
};

override _build_entry_tick => sub {
    my $self = shift;

    my $entry_epoch_from_shortcode = $self->build_parameters->{entry_epoch};

    return $self->_tick_accessor->tick_at($entry_epoch_from_shortcode) if $entry_epoch_from_shortcode;

    return $self->_tick_accessor->tick_at($self->date_start->epoch, {allow_inconsistent => 1});
};

override _build_ticks_for_tick_expiry => sub {
    my $self       = shift;
    my $entry_tick = $self->entry_tick;
    return [] unless ($self->tick_expiry and $entry_tick);
    return $self->_tick_accessor->ticks_in_between_start_limit({
        start_time => $entry_tick->epoch,
        limit      => $self->ticks_to_expiry,
    });
};

override _build_tick_stream => sub {
    my $self = shift;

    return unless $self->tick_expiry;

    my @all_ticks = @{$self->ticks_for_tick_expiry};

    # for path dependent contract, there should be no more tick after close tick
    # because the contract technically has expired
    if ($self->is_path_dependent and $self->close_tick) {
        @all_ticks = grep { $_->epoch <= $self->close_tick->epoch } @all_ticks;
    }

    return [map { {epoch => $_->epoch, tick => $_->quote, tick_display_value => $self->underlying->pipsized_value($_->quote)} } @all_ticks];

};

=head2 _build_hit_tick

Turbos expires worthless if barrier is breached.

If take profit is defined, turbos expires with profit when take profit value is breached.

Returns a tick that breached either of the contract conditions, else returns undef.

=cut

sub _build_hit_tick {
    my $self = shift;

    return undef unless $self->entry_tick;
    return $self->_hit_barrier     if $self->_hit_barrier;
    return $self->_hit_take_profit if $self->_hit_take_profit;
    return undef;
}

=head2 _hit_barrier

Returns the tick if barrier is breached, else returns undef.

=cut

sub _hit_barrier {
    my $self = shift;

    # date_start + 1 applies for all expiry type (tick, intraday & multi-day). Basically the first tick
    # that comes into play is the tick after the contract start time, not at the contract start time.
    my $start_time     = $self->date_start->epoch + 1;
    my $end_time       = max($start_time, min($self->date_pricing->epoch, $self->date_expiry->epoch));
    my %hit_conditions = (
        start_time => $start_time,
        end_time   => $end_time,
        ($self->_hit_conditions_barrier),
    );

    return $self->_tick_accessor->breaching_tick(%hit_conditions);
}

=head2 _hit_take_profit

Returns the tick if take profit is breached, else returns undef.

=cut

sub _hit_take_profit {
    my $self = shift;

    if (defined $self->take_profit and $self->take_profit->{amount}) {
        my $start_time     = Date::Utility->new($self->take_profit->{date})->epoch + 1;
        my $end_time       = max($start_time, min($self->date_pricing->epoch, $self->date_expiry->epoch));
        my %hit_conditions = (
            start_time              => $start_time,
            end_time                => $end_time,
            $self->take_profit_side => $self->take_profit_barrier_value,
        );

        return $self->_tick_accessor->breaching_tick(%hit_conditions);
    }

    return undef;
}

=head2 ticks_to_expiry

The number of ticks required from contract start to expiry. Includes entry tick.

=cut

sub ticks_to_expiry {
    my $self = shift;

    return $self->tick_count + 1;
}

=head2 _build_payout

For turbos options it is not possible to define payout.

=cut

sub _build_payout {
    return 0;
}

=head2 _validation_methods

all validation methods needed for turbos

=cut

sub _validation_methods {
    my ($self) = @_;

    my @validation_methods =
        qw(_validate_offerings _validate_input_parameters _validate_start_and_expiry_date _validate_feed _validate_rollover_blackout);
    push @validation_methods, qw(_validate_trading_times)  unless $self->underlying->always_available;
    push @validation_methods, '_validate_price_non_binary' unless $self->skips_price_validation;
    push @validation_methods, '_validate_volsurface'       unless $self->underlying->volatility_surface_type eq 'flat';

    # add turbos specific validations
    push @validation_methods, qw(_validate_barrier_choice _validate_stake validate_take_profit) unless $self->for_sale;

    return \@validation_methods;
}

=head2 strike_price_choices

calculates and return strike price choices based on delta and expiry

=cut

sub strike_price_choices {
    my ($self)                 = @_;
    my $symbol                 = $self->underlying->symbol;
    my $sigma                  = $self->fixed_config->{$symbol}{sigma}              || undef;
    my $min_distance_from_spot = $self->per_symbol_config->{min_distance_from_spot} || undef;
    my $num_of_barriers        = $self->per_symbol_config->{num_of_barriers}        || undef;
    unless (defined $sigma && defined $min_distance_from_spot && defined $num_of_barriers) {
        BOM::Product::Exception->throw(error_code => 'MissingRequiredContractConfig');
    }
    my $args = {
        underlying             => $self->underlying,
        current_spot           => $self->current_spot,
        sigma                  => $sigma,
        n_max                  => $self->n_max,
        min_distance_from_spot => $min_distance_from_spot,
        num_of_barriers        => $num_of_barriers,
    };

    my $key             = "turbos:${symbol}:${min_distance_from_spot}:${num_of_barriers}";
    my $barrier_choices = [split(':', $self->_redis_read->get($key) || '')];
    if (scalar @$barrier_choices) {
        my $last_spot = shift @$barrier_choices;

        my $threshold_coefficient = $sigma * sqrt(7200 / BOM::Product::Contract::Strike::Turbos::SECONDS_IN_A_YEAR);
        if (
            not(   $self->current_spot > (1 + $threshold_coefficient) * $last_spot
                || $self->current_spot < (1 - $threshold_coefficient) * $last_spot))
        {
            return BOM::Product::Contract::Strike::Turbos::prepend_barrier_offsets($self->code, $barrier_choices);
        }
    }

    $barrier_choices = BOM::Product::Contract::Strike::Turbos::strike_price_choices($args);
    $self->_redis_write->set($key, join(':', $self->current_spot, @$barrier_choices), EX => 60 * 60);

    return BOM::Product::Contract::Strike::Turbos::prepend_barrier_offsets($self->code, $barrier_choices);
}

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
            barrier_choices => $strike_price_choices
        },
    };
}

=head2 require_price_adjustment

Not needed require price adjustment

=cut

sub require_price_adjustment {
    return 0;
}

=head2 _order

limit orders (E.g. take profit order)

=cut

has _order => (
    is      => 'ro',
    default => sub { {} });

=head2 display_barrier

Decimal places to dispaly barrier is equal to underlying's pip size.

=cut

sub display_barrier {
    my $self = shift;

    my $precision = $self->underlying->pip_size;

    return roundcommon($precision, $self->barrier->as_absolute);
}

=head2 validate_take_profit

validate take profit amount
it should be 0 < amount <= max_take_profit

=cut

sub validate_take_profit {
    my $self = shift;
    #take_profit will be an argument if we are validating contract update paramters
    my $take_profit = $self->pricing_new ? $self->take_profit : shift;

    #if there is no take profit order it should be valid
    # amount is undef if we want to cancel and it should always be valid
    return unless ($take_profit and defined $take_profit->{amount});

    if (my $decimal_error = _validate_decimal($take_profit->{amount}, $self->currency)) {
        return $decimal_error;
    }

    if ($take_profit->{amount} <= 0) {
        return {
            message           => 'take profit too low',
            message_to_client => [$ERROR_MAPPING->{TakeProfitTooLow}, financialrounding('price', $self->currency, 0)],
            details           => {field => 'take_profit'},
            code              => 'TakeProfitTooLow'
        };
    }

    if ($take_profit->{amount} > $self->_max_allowable_take_profit) {
        return {
            message           => 'take profit too high',
            message_to_client =>
                [$ERROR_MAPPING->{TakeProfitTooHigh}, financialrounding('price', $self->currency, $self->_max_allowable_take_profit)],
            details => {field => 'take_profit'},
            code    => 'TakeProfitTooHigh'
        };
    }

    return;
}

=head2 _validate_decimal

validate the precision of TP amount

=cut

sub _validate_decimal {
    my ($amount, $currency) = @_;

    my $order_precision      = Format::Util::Numbers::get_precision_config()->{price}->{$currency};
    my $precision_multiplier = 10**$order_precision;

    unless (isint($amount * $precision_multiplier)) {
        return {
            message           => 'too many decimal places',
            message_to_client => [$ERROR_MAPPING->{LimitOrderIncorrectDecimal}, $order_precision],
            details           => {field => 'take_profit'},
        };
    }
    return;
}

=head2 _validate_stake

validate stake based on financial underlying risk profile defined in backoffice

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

=head2 pnl

The current profit/loss of the contract.

=cut

sub pnl {
    my $self = shift;

    return financialrounding('price', $self->currency, $self->bid_price - $self->_user_input_stake);
}

=head2 _get_symbol_volatility

Gets volatility for symbols with Flat VolSurface.

=cut

sub _get_symbol_volatility {
    my $symbol = shift;

    my $vol = LoadFile('/home/git/regentmarkets/bom-market/config/files/flat_volatility.yml');

    return $vol->{$symbol};
}

=head2 _max_allowable_take_profit

Calculates maximum allowable take profit value.

=cut

sub _max_allowable_take_profit {
    my $self = shift;

    return _get_symbol_volatility($self->underlying->symbol) * $self->n_max * $self->_user_input_stake;
}

1;
