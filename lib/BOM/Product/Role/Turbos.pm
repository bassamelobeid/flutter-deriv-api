package BOM::Product::Role::Turbos;

use Moose::Role;
use Time::Duration::Concise;
use Format::Util::Numbers qw/financialrounding formatnumber/;
use Scalar::Util::Numeric qw(isint);
use List::Util            qw/min max/;
use YAML::XS              qw(LoadFile);
use POSIX                 qw(ceil floor);
use Format::Util::Numbers qw/roundcommon/;

use BOM::Config::Redis;
use BOM::Product::Exception;
use BOM::Product::Static;
use BOM::Product::Contract::Strike::Turbos;

my $turbos_config = LoadFile('/home/git/regentmarkets/bom/config/files/turbos.yml');
my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

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

# has [qw(max_duration duration max_payout take_profit tick_count tick_size_barrier basis_spot tick_count_after_entry pnl)] => (
has [qw(number_of_contracts n_max)] => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 _build_n_max

Maximum number of contracts. For barrier choices calculation

=cut

sub _build_n_max {
    my $self = shift;

    my $max_multiplier_stake =
        $turbos_config->{$self->underlying->symbol} ? $turbos_config->{$self->underlying->symbol}->{max_multiplier_stake}->{$self->currency} : undef;
    my $max_multiplier =
        $turbos_config->{$self->underlying->symbol} ? $turbos_config->{$self->underlying->symbol}->{max_multiplier} : undef;

    unless (defined $max_multiplier_stake && defined $max_multiplier) {
        BOM::Product::Exception->throw(error_code => 'MissingRequiredContractConfig');
    }

    return $max_multiplier_stake * $max_multiplier / $self->current_spot;
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

    my $expiry = $self->expiry_type;
    my $avg_tick_size_down =
        $turbos_config->{$self->underlying->symbol} ? $turbos_config->{$self->underlying->symbol}->{average_tick_size_down} : undef;
    my $ticks_commission_down =
        $turbos_config->{$self->underlying->symbol} ? $turbos_config->{$self->underlying->symbol}->{"ticks_commission_down_${expiry}"} : undef;
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

    my $expiry = $self->expiry_type;
    my $avg_tick_size_up =
        $turbos_config->{$self->underlying->symbol} ? $turbos_config->{$self->underlying->symbol}->{average_tick_size_up} : undef;
    my $ticks_commission_up =
        $turbos_config->{$self->underlying->symbol} ? $turbos_config->{$self->underlying->symbol}->{"ticks_commission_up_${expiry}"} : undef;
    unless (defined $avg_tick_size_up && defined $ticks_commission_up) {
        BOM::Product::Exception->throw(error_code => 'MissingRequiredContractConfig');
    }

    return $avg_tick_size_up * $ticks_commission_up;
}

=head2 _build_number_of_contracts

Calculate implied number of contracts.
n = Stake / Option Price
We need to use entry tick to calculate this figure.

=cut

sub _build_number_of_contracts {
    my $self = shift;

    my $contract_price = $self->_contract_price;

    my $number_of_contracts = $contract_price ? sprintf("%.10f", $self->_user_input_stake / $contract_price) : $self->_contracts_limit->{min};

    if ($number_of_contracts > $self->_contracts_limit->{max}) {
        BOM::Product::Exception->throw(
            error_code => 'TurbosContractNumberMaxLimit',
            error_args => [int($self->_contracts_limit->{max} * $self->_contract_price)]);
    }

    if ($number_of_contracts < $self->_contracts_limit->{min}) {
        BOM::Product::Exception->throw(
            error_code => 'TurbosContractNumberMinLimit',
            error_args => [int($self->_contracts_limit->{min} * $self->_contract_price)]);
    }

    return $number_of_contracts;
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

    my $symbol               = $self->underlying->symbol;
    my $max_multiplier       = $turbos_config->{$symbol}{max_multiplier};
    my $max_multiplier_stake = $turbos_config->{$symbol}{max_multiplier_stake}->{$self->currency};
    my $min_multiplier       = $turbos_config->{$symbol}{min_multiplier};
    my $min_multiplier_stake = $turbos_config->{$symbol}{min_multiplier_stake}->{$self->currency};

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

has [qw(min_stake max_stake)] => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 _build_min_stake

get current min stake

=cut

sub _build_min_stake {
    my $self = shift;

    my $distance  = abs($self->entry_tick->quote - $self->barrier->as_absolute);
    my $min_stake = $self->_contracts_limit->{min} * $distance;

    return financialrounding('price', $self->currency, $min_stake);
}

=head2 _build_max_stake

get current max stake

=cut

sub _build_max_stake {
    my $self = shift;

    my $distance  = abs($self->entry_tick->quote - $self->barrier->as_absolute);
    my $max_stake = $self->_contracts_limit->{max} * $distance;

    return financialrounding('price', $self->currency, $max_stake);
}

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

    return undef unless $self->entry_tick;

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

=head2 ticks_to_expiry

The number of ticks required from contract start time to expiry.

=cut

sub ticks_to_expiry {
    my $self = shift;

    return $self->tick_count;
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

    my @validation_methods = qw(_validate_offerings _validate_input_parameters _validate_start_and_expiry_date);
    push @validation_methods, qw(_validate_trading_times) unless $self->underlying->always_available;
    # push @validation_methods, '_validate_barrier'         unless $self->for_sale || $args->{skip_barrier_validation};
    # push @validation_methods, '_validate_barrier_type' unless $self->for_sale;
    push @validation_methods, '_validate_feed';
    push @validation_methods, '_validate_price'      unless $self->skips_price_validation;
    push @validation_methods, '_validate_volsurface' unless $self->underlying->volatility_surface_type eq 'flat';
    push @validation_methods, '_validate_rollover_blackout';

    # add turbos specific validations
    # push @validation_methods, '_validate_number_of_contracts';
    push @validation_methods, '_validate_barrier_choice' unless $self->for_sale;
    push @validation_methods, '_validate_stake'          unless $self->for_sale;

    return \@validation_methods;
}

=head2 strike_price_choices

calculates and return strike price choices based on delta and expiry

=cut

sub strike_price_choices {
    my ($self)                 = @_;
    my $symbol                 = $self->underlying->symbol;
    my $sigma                  = $turbos_config->{$symbol}->{sigma}                  || undef;
    my $min_distance_from_spot = $turbos_config->{$symbol}->{min_distance_from_spot} || undef;
    my $num_of_barriers        = $turbos_config->{$symbol}->{num_of_barriers}        || undef;
    unless (defined $sigma && defined $min_distance_from_spot && defined $num_of_barriers) {
        BOM::Product::Exception->throw(error_code => 'MissingRequiredContractConfig');
    }

    my $args = {
        underlying             => $self->underlying,
        current_spot           => $self->current_spot,
        sigma                  => $sigma,
        n_max                  => $self->n_max,
        sentiment              => $self->sentiment,
        min_distance_from_spot => $min_distance_from_spot,
        num_of_barriers        => $num_of_barriers,
    };

    my $code = $self->code;
    my $key  = "turbos:${code}:${symbol}";
    my $r    = BOM::Config::Redis::redis_replicated_write();

    my $barrier_choises = [split(':', $r->get($key) || '')];
    if (scalar @$barrier_choises) {
        my $last_spot = shift @$barrier_choises;

        my $treshold_coef = $sigma * sqrt(7200 / BOM::Product::Contract::Strike::Turbos::SECONDS_IN_A_YEAR);
        if (
            not(   $self->current_spot > (1 + $treshold_coef) * $last_spot
                || $self->current_spot < (1 - $treshold_coef) * $last_spot))
        {
            # warn 'cash hit';
            return $barrier_choises;
        }
        # warn 'threshold hit';
    } else {
        # warn 'empty cash';
    }

    $barrier_choises = BOM::Product::Contract::Strike::Turbos::strike_price_choices($args);

    # warn 'cash set';
    # using watch and multi to avoid race condition
    $r->watch($key);
    $r->multi();
    $r->set($key, join(':', $self->current_spot, @$barrier_choises), EX => 60 * 60);
    $r->exec();

    return $barrier_choises;
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

    # not validating payout max as turbos doesn't have a payout until expiry
    return undef;
};

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

#TODO:JB roundup & rounddown methods are common across non-binaries.
#Refactor to utility method when all products are launched

=head2 roundup

Utility method to round up a value
roundup(638.4900001, 0.001) = 638.491

=cut

sub roundup {
    my ($value_to_round, $precision) = @_;

    $precision = 1 if $precision == 0;
    my $res = ceil($value_to_round / $precision) * $precision;
    #use roundcommon on the result to add trailing zeros and return a string
    return roundcommon($precision, $res);
}

=head2 rounddown

Utility method to round down a value
roundown(638.4209, 0.001) = 638.420

=cut

sub rounddown {
    my ($value_to_round, $precision) = @_;

    $precision = 1 if $precision == 0;
    my $res = floor($value_to_round / $precision) * $precision;
    #use roundcommon on the result to add trailing zeros and return a string
    return roundcommon($precision, $res);
}

=head2 validate_take_profit

validate take profit amount
it should be 0 < amount <= max_take_profit

=cut

sub validate_take_profit {
    my $self = shift;
    #take_profit will be an argument if we are validating contract update paramters
    my $take_profit = shift // $self->take_profit;

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

    my $stake = $self->_user_input_stake;
    if ($stake < $self->min_stake) {
        return {
            message           => 'minimum stake limit',
            message_to_client => [$ERROR_MAPPING->{InvalidMinStake}, financialrounding('price', $self->currency, $self->min_stake)]};
    }
    if ($stake > $self->max_stake) {
        return {
            message           => 'maximum stake limit',
            message_to_client => [$ERROR_MAPPING->{InvalidMaxStake}, financialrounding('price', $self->currency, $self->max_stake)]};
    }
}

=head2 pnl

The current profit/loss of the contract.

=cut

sub pnl {
    my $self = shift;

    return financialrounding('price', $self->currency, $self->bid_price - $self->_user_input_stake);
}

1;
