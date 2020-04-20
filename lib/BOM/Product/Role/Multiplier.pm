package BOM::Product::Role::Multiplier;

use Moose::Role;

use List::Util qw(max first);
use Date::Utility;
use BOM::Product::Exception;
use BOM::Product::LimitOrder;
use Format::Util::Numbers qw(financialrounding);
use BOM::Config::Runtime;
use YAML::XS qw(LoadFile);
use BOM::Config::QuantsConfig;
use BOM::Config::Chronicle;
use Machine::Epsilon;
use Scalar::Util qw(looks_like_number);

use constant {
    MIN_COMMISSION_AMOUNT     => 0.02,
    BARRIER_ADJUSTMENT_FACTOR => 0.5826,
};

my $ERROR_MAPPING   = BOM::Product::Static::get_error_mapping();
my $GENERIC_MAPPING = BOM::Product::Static::get_generic_mapping();

my @supported_orders = qw(stop_loss take_profit stop_out);

sub BUILD {
    my $self = shift;

    unless ($self->multiplier) {
        BOM::Product::Exception->throw(
            error_code => 'MissingRequiredContractParams',
            error_args => ['multiplier'],
            details    => {field => 'basis'},
        );
    }

    # We want to charge a minimum commission for each contract.
    # Since, commission is a function of barrier calculation, we will need to fix it at BUILD
    my $commission = $self->_multiplier_config->{commission};

    unless (defined $commission) {
        $self->_add_error({
            message           => 'multiplier commission not defined for ' . $self->underlying->symbol,
            message_to_client => $ERROR_MAPPING->{InvalidInputAsset},
        });
        $commission = 0;
    }

    my $commission_amount = $commission * $self->_user_input_stake * $self->multiplier;

    if ($commission_amount < MIN_COMMISSION_AMOUNT) {
        $commission = MIN_COMMISSION_AMOUNT / ($self->_user_input_stake * $self->multiplier);
        $commission_amount = MIN_COMMISSION_AMOUNT;
    }

    $self->commission($commission);
    $self->commission_amount(financialrounding('price', $self->currency, $commission_amount));

    return;
}

=head2 commission_amount

Commission charged in payout currency amount. A minimum of 0.02 is imposed per contract.

=head2 commission

Commission in decimal amount. E.g. 0.01 = 1%

=cut

has [qw(commission_amount commission)] => (
    is => 'rw',
);

=head2 cancel_price

The amount user gets back if deal cancellation was executed.

=cut

has cancel_price => (
    is         => 'ro',
    init_arg   => undef,
    lazy_build => 1,
);

sub _build_cancel_price {
    my $self = shift;

    return 0 unless $self->cancellation;
    return $self->_user_input_stake;
}

=head2 multiplier

how many units?

=cut

has multiplier => (
    is      => 'ro',
    default => undef,
);

=head2 date_expiry

The expiry time of the contract. Non-binary (multiplier contract), does not have expiries.
But, we need an expiry time for every contract the database. Hence, hard-coding a 100-year expiry time here.

=cut

has date_expiry => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_date_expiry',
);

sub _build_date_expiry {
    my $self = shift;

    return $self->date_start->plus_time_interval(100 * 365 . 'd');
}

=head2 take_profit

A BOM::Product::LimitOrder object. Functions as an expiry condition where
contract is closed when take profit is breached.

=head2 stop_out

A BOM::Product::LimitOrder object. Functions as ann expiry condition where
contract is closed when stop out is breached.

=cut

has [qw(basis_spot take_profit stop_loss stop_out)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_basis_spot {
    my $self = shift;

    return $self->current_spot if $self->pricing_new;

    # after consistent tick, we should be able to use $underlying->tick_at($self->date_start->epoch);
    return $self->stop_out->basis_spot if $self->stop_out and $self->stop_out->basis_spot;
    return BOM::Product::Exception->throw(
        error_code => 'MissingBasisSpot',
    );
}

=head2 new_order

creates a new BOM::Product::LimitOrder object.

->new_order({take_profit => 10});

=cut

sub new_order {
    my ($self, $params) = @_;

    my ($order_type, $order_amount) = %$params;

    # internally converts the order amount to negative value
    $order_amount *= -1 if (($order_type eq 'stop_loss' or $order_type eq 'stop_out') and defined $order_amount);

    return BOM::Product::LimitOrder->new(
        order_type   => $order_type,
        order_amount => $order_amount,
        order_date   => $self->date_pricing,
        basis_spot   => $self->basis_spot,
        %{$self->_limit_order_args});
}

sub _build_stop_loss {
    my $self = shift;

    return undef unless defined $self->_order->{stop_loss};

    if ($self->pricing_new) {
        return $self->new_order({stop_loss => $self->_order->{stop_loss}});
    }

    my $args = $self->_order->{stop_loss};

    return BOM::Product::LimitOrder->new({%$args, %{$self->_limit_order_args}});
}

sub _build_take_profit {
    my $self = shift;

    return undef unless defined $self->_order->{take_profit};

    if ($self->pricing_new) {
        return $self->new_order({take_profit => $self->_order->{take_profit}});
    }

    my $args = $self->_order->{take_profit};

    return BOM::Product::LimitOrder->new({%$args, %{$self->_limit_order_args}});
}

sub _build_stop_out {
    my $self = shift;

    # If it is a new contract, construct stop_out using configs from backoffice
    if ($self->pricing_new) {
        # TODO: This should be changeable from backoffice
        my $stop_out_percentage = 0;
        my $order_amount        = (1 - $stop_out_percentage / 100) * $self->_user_input_stake;

        return $self->new_order({stop_out => $order_amount});
    }

    # if stop out is not defined for non-pricing_new, then we have a problem.
    unless ($self->_order->{stop_out}) {
        BOM::Product::Exception->throw(
            error_code => 'CannotValidateContract',
            details    => {field => ''},
        );
    }

    return BOM::Product::LimitOrder->new({%{$self->_order->{stop_out}}, %{$self->_limit_order_args}});
}

=head2 sell_time

The time when the contract is closed (either manually from the user or when it breached expiry condition)

=cut

has sell_time => (
    is      => 'rw',
    default => undef,
);

=head2 is_expired

Is this contract expired?

Contract can expire when:
- stop out level is breached without insurance
- take profit level is breached

Returns a boolean.

=cut

sub is_expired {
    my $self = shift;

    # When take profit or stop loss is very small, the chance of contract expiring on next tick increases.
    # This triggers an error when we try to sell the contract where buy_time == sell_time. Delaying the sell to
    # the next second when this happens.
    if (not $self->pricing_new and $self->date_pricing->epoch == $self->date_start->epoch) {
        return 0;
    }

    # contract expires if it hits either of these barriers:
    # - stop out
    # - stop loss (if defined)
    # - take profit (if defined)
    if ($self->hit_tick) {
        # if contract hit stop out before the end of deal cancellation period, the initial stake is returned
        if ($self->is_cancelled) {
            $self->value(financialrounding('price', $self->currency, $self->_user_input_stake));
            return 1;
        } else {
            my $value =
                $self->_user_input_stake + max($self->_calculate_pnl_at_tick({at_tick => $self->hit_tick}), -$self->_user_input_stake);
            $self->value(financialrounding('price', $self->currency, $value));
            return 1;
        }
    } elsif ($self->date_pricing->is_after($self->date_expiry)) {
        # we don't expect a contract to reach date_expiry, but we it does, we will need to close
        # it at current tick.
        my $value =
            $self->_user_input_stake + max($self->_calculate_pnl_at_tick({at_tick => $self->current_tick}), -$self->_user_input_stake);
        $self->value(financialrounding('price', $self->currency, $value));
        return 1;
    }

    return 0;
}

=head2 hit_tick

=cut

has hit_tick => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_hit_tick {
    my $self = shift;

    # hit tick is not relevant when the contract hasn't started
    return undef if $self->pricing_new;
    # we can't really combined the search for stop out and take profit because
    # we can potentially look at different periods once we allow changing of take profit
    # when contract is opened.
    my $end_time;
    if ($self->sell_time) {
        $end_time = Date::Utility->new($self->sell_time)->epoch;
    } else {
        $end_time = $self->date_pricing->is_before($self->date_expiry) ? $self->date_pricing->epoch : $self->date_expiry->epoch;
    }

    my $stop_out_tick = $self->_get_breaching_tick($self->stop_out->order_date->epoch,
        $end_time, {$self->stop_out_side => $self->underlying->pipsized_value($self->stop_out->barrier_value)});
    my $take_profit_tick =
        ($self->take_profit and defined $self->take_profit->barrier_value)
        ? $self->_get_breaching_tick($self->take_profit->order_date->epoch,
        $end_time, {$self->take_profit_side => $self->underlying->pipsized_value($self->take_profit->barrier_value)})
        : undef;
    my $stop_loss_tick =
        ($self->stop_loss and defined $self->stop_loss->barrier_value)
        ? $self->_get_breaching_tick($self->stop_loss->order_date->epoch,
        $end_time, {$self->stop_loss_side => $self->underlying->pipsized_value($self->stop_loss->barrier_value)})
        : undef;

    # there's a small chance both stop out and take profit can happen (mostly due to delay in sell)
    # let's not take any chances.
    if (($stop_loss_tick or $stop_out_tick) and $take_profit_tick) {
        # stop_loss_tick should always have higher priority over stop_out if both were breached
        my $compare_tick = $stop_loss_tick // $stop_out_tick;
        return ($compare_tick->epoch < $take_profit_tick->epoch) ? $compare_tick : $take_profit_tick;
    } elsif ($stop_out_tick) {
        return $stop_out_tick;
    } elsif ($take_profit_tick) {
        return $take_profit_tick;
    } elsif ($stop_loss_tick) {
        return $stop_loss_tick;
    }

    return undef;
}

sub _get_breaching_tick {
    my ($self, $start_time, $end_time, $barrier_args) = @_;

    return $self->underlying->breaching_tick(
        start_time => $start_time,
        end_time   => $end_time,
        %$barrier_args,
    );
}

sub _calculate_pnl_at_tick {
    my ($self, $args) = @_;

    # if there's a hit_tick, pnl is calculated with that tick
    my $nth_tick = $args->{at_tick} or die 'calculating pnl without a reference tick';
    my $commission = $self->commission // 0;

    my $main_pnl =
        $self->_user_input_stake * ($self->_pnl_sign * ($nth_tick->quote - $self->basis_spot) / $self->basis_spot - $commission) * $self->multiplier;

    return financialrounding('price', $self->currency, $main_pnl);
}

=head2 current_pnl

Current PnL of the contract.

=cut

sub current_pnl {
    my $self = shift;

    return '0.00' if $self->pricing_new;

    return $self->_calculate_pnl_at_tick({at_tick => $self->hit_tick}) if $self->hit_tick;
    return $self->_calculate_pnl_at_tick({at_tick => $self->current_tick});
}

=head2 bid_price

Bid price which will be saved into sell_price in financial_market_bet table.

=cut

override '_build_bid_price' => sub {
    my $self = shift;

    return $self->value if $self->is_expired;
    return $self->_user_input_stake + $self->current_pnl();
};

override '_build_ask_price' => sub {
    my $self = shift;

    return $self->_user_input_stake + $self->cost_of_cancellation;
};

=head2 pricing engine
=head2 pricing_engine_name

Pricing engine and pricing engine name are undefined.

=cut

override '_build_pricing_engine' => sub {
    return undef;
};

override '_build_pricing_engine_name' => sub {
    return '';
};

# basis spot is stored in the database to 100% ensure that
# limit order calculations are always correct.
override '_build_entry_tick' => sub {
    my $self = shift;

    return undef if $self->pricing_new;

    my $tick = $self->underlying->tick_at($self->date_start->epoch);
    # less wait for consistent entry tick here.
    return undef unless $tick;
    # due to potential inconsistent tick during pricing time (could be due to distribution delay or tick receives later in the second),
    # we need to check it the tick that is used when the contract is bought
    if (abs($self->basis_spot - $tick->quote) < machine_epsilon()) {
        return $tick;
    }

    # if it is not the tick at $self->date_start->epoch, it has to be tick 1 second before that
    return $self->underlying->tick_at($self->date_start->epoch - 1);
};

override 'shortcode' => sub {
    my $self = shift;

    return join '_',
        (
        uc $self->code,
        uc $self->underlying->symbol,
        $self->_user_input_stake, $self->multiplier,
        $self->date_start->epoch,
        $self->date_expiry->epoch,
        $self->cancellation, $self->cancellation_tp,
        );
};

sub is_valid_to_sell {
    my ($self, $args) = @_;

    if ($self->is_sold) {
        $self->_add_error({
            message           => 'Contract already sold',
            message_to_client => [$ERROR_MAPPING->{ContractAlreadySold}],
        });
        return 0;
    }

    return 1 if $self->is_expired;

    foreach my $method (qw(_validate_trading_times _validate_feed _validate_sell_pnl)) {
        if (my $error = $self->$method($args)) {
            $self->_add_error($error);
            return 0;
        }
    }

    return 1;
}

sub is_valid_to_cancel {
    my $self = shift;

    if ($self->is_sold) {
        $self->_add_error({
            message           => 'Contract is sold',
            message_to_client => [$ERROR_MAPPING->{ContractAlreadySold}],
        });
        return 0;
    }

    # if deal cancellation is not purchased, then no.
    unless ($self->cancellation) {
        $self->_add_error({
            message           => 'Deal cancellation not purchased',
            message_to_client => [$ERROR_MAPPING->{DealCancellationNotBought}],
        });
        return 0;
    }

    # cancellation period is inclusive of the cancellation expiry time.
    if ($self->date_pricing->is_after($self->cancellation_expiry)) {
        $self->_add_error({
            message           => 'Deal cancellation expired',
            message_to_client => [$ERROR_MAPPING->{DealCancellationExpired}],
        });
        return 0;
    }

    return 1;
}

sub available_orders_for_display {
    my ($self, $new_orders) = @_;

    my %available = ();
    foreach my $name (@supported_orders) {
        my $new_order = $new_orders->{$name};
        my $order_obj = ($new_order and $new_order->order_type eq $name) ? $new_order : ($self->can($name) and $self->$name) ? $self->$name : undef;
        next unless $order_obj;
        $available{$name} = {
            display_name => $GENERIC_MAPPING->{$name},
            value        => $order_obj->barrier_value,
            order_amount => $order_obj->order_amount,
            order_date   => $order_obj->order_date->epoch
        };
    }

    return \%available;
}

has user_defined_multiplier => (
    is      => 'ro',
    default => 1,
);

sub _build_payout {
    return 0;
}

sub require_price_adjustment {
    return 0;
}

sub app_markup_dollar_amount {
    # we will not allow app_markup for multiplier
    return 0;
}

sub supported_orders {
    return \@supported_orders;
}

=head2 available_orders

Shows the most recent limit orders for a contract.

This is formatted in a way that it can be directly put into PRICER_KEYS.

=cut

sub available_orders {
    my ($self, $new_orders) = @_;

    my @available_orders = ();

    foreach my $order_name (sort @supported_orders) {
        my $new_order = $new_orders->{$order_name};
        if ($new_order and $order_name eq $new_order->order_type) {
            push @available_orders, ($order_name, $self->_extract_details($new_order));
        } elsif ($self->can($order_name) && $self->$order_name) {
            push @available_orders, ($order_name, $self->_extract_details($self->$order_name));
        }
    }

    return \@available_orders;
}

sub _extract_details {
    my ($self, $order_object) = @_;

    my $order_amount = $order_object->order_amount ? $order_object->order_amount + 0 : undef;
    # this details needs to in the following order (sort qw(order_type order_amount basis_spot order_date)). Do not change the order!
    return [
        'basis_spot', $order_object->basis_spot + 0, 'order_amount',
        financialrounding('price', $self->currency, $order_amount), 'order_date', int($order_object->order_date->epoch),
        'order_type', $order_object->order_type
    ];
}

sub stop_out_side {
    my $self = shift;
    return $self->sentiment eq 'up' ? 'lower' : 'higher';
}

sub stop_loss_side {
    my $self = shift;
    return $self->stop_out_side;
}

sub take_profit_side {
    my $self = shift;
    return $self->sentiment eq 'up' ? 'higher' : 'lower';
}

sub commission_amount {
    my $self = shift;

    my $commission = $self->commission // 0;
    my $commission_amount = $commission * $self->_user_input_stake * $self->multiplier;

    if ($commission_amount < MIN_COMMISSION_AMOUNT) {

    }
}

=head2 cancellation

deal cancellation duration

=head2 cancellaton_tp

deal cancellation price is a function of take profit, hence we need to record it.

=cut

has cancellation => (
    is      => 'ro',
    default => 0,
);

has cancellation_tp => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_cancellation_tp {
    my $self = shift;

    return 0 unless $self->take_profit;
    return $self->take_profit->order_amount;
}

has cancellation_expiry => (
    is         => 'ro',
    init_arg   => undef,
    lazy_build => 1,
);

sub _build_cancellation_expiry {
    my $self = shift;

    my $cancellation_duration = $self->cancellation;
    return undef unless $cancellation_duration;

    return $self->date_start->plus_time_interval($cancellation_duration);
}

sub close_tick {
    my $self = shift;

    return $self->hit_tick if $self->hit_tick;

    return undef unless $self->is_sold;
    # if it is not hit tick then we need to check for the tick used at sell time.
    my $sell_epoch = Date::Utility->new($self->sell_time)->epoch;

    # this is sell at market, it could be that the contract is sold at previous tick
    foreach my $args ([$sell_epoch, {allow_inconsistent => 1}], [$sell_epoch - 1]) {
        my $tick;
        if ($tick = $self->underlying->tick_at(@$args)
            and abs($self->sell_price - ($self->_user_input_stake + $self->_calculate_pnl_at_tick({at_tick => $tick}))) < machine_epsilon)
        {
            return $tick;
        }
    }

    return undef;
}

=head2 cost_of_cancellation

We allow client to purchase deal cancellation on top of their main contract
at a premium.

=cut

sub cost_of_cancellation {
    my $self = shift;

    # if there's no cancellation request, do not charge
    return 0 unless $self->cancellation;

    my $dc_model_price = $self->cancellation_tp ? $self->_american_binary_knockout + $self->_double_knockout : $self->_standard_barrier_option;
    my $cost           = $self->_user_input_stake * $self->multiplier * $dc_model_price;
    my $dc_ask         = $cost * (1 + $self->_multiplier_config->{cancellation_commission});

    return financialrounding('price', $self->currency, $dc_ask);
}

### PRIVATE METHODS ###

sub _validation_methods {
    # For multiplier contract we will validation:
    # - offerings (if contract is disabled from backoffice)
    # - start time (if start time is in the past or in the future)
    # - trading times (if market is open)
    # - feed (if feed is too old)
    return [
        qw(_validate_offerings _validate_input_parameters _validate_trading_times _validate_feed _validate_commission _validate_multiplier_range _validate_orders _validate_cancellation)
    ];
}

sub _validate_cancellation {
    my $self = shift;

    my $app_config = BOM::Config::Runtime->instance->app_config;

    my $market = $self->underlying->market->name;

    unless ($app_config->quants->suspend_deal_cancellation->can($market)) {
        return {
            message           => 'deal cancellation suspension config not set',
            message_to_client => $ERROR_MAPPING->{DealCancellationPurchaseSuspended},
            details           => {field => 'deal_cancellation'},
        };
    }

    if ($app_config->quants->suspend_deal_cancellation->$market and $self->cancellation) {
        return {
            message           => 'deal cancellation suspended',
            message_to_client => $ERROR_MAPPING->{DealCancellationPurchaseSuspended},
            details           => {field => 'deal_cancellation'},
        };
    }

    return unless $self->cancellation;

    # currently only allow '1h' as deal cancellation duration. Will expand this to /\d+(?:h|m)/
    if ($self->cancellation ne '1h') {
        return {
            message           => 'invalid deal cancellation duration',
            message_to_client => $ERROR_MAPPING->{InvalidDealCancellation},
            details           => {field => 'cancellation'},
        };
    }

    unless ($self->cancellation_expiry->is_after($self->date_start)) {
        return {
            message           => 'invalid deal cancellation duration',
            message_to_client => $ERROR_MAPPING->{InvalidDealCancellation},
            details           => {field => 'cancellation'},
        };
    }

    return;
}

sub _validate_orders {
    my $self = shift;

    foreach my $order_name (@supported_orders) {
        # at the beginning of contract purchase, stop loss more be more than commission to
        # avoid contract closing immediately after purchase.
        my $pnl =
            ($self->pricing_new and $order_name eq 'stop_loss')
            ? -1 * $self->commission_amount
            : $self->current_pnl;
        if ($self->$order_name and not $self->$order_name->is_valid($pnl, $self->currency, $self->pricing_new)) {
            return $self->$order_name->validation_error;
        }
    }

    # Deal cancellation order cannot be set together with stop loss even though these orders work independently.
    # If a contract is closed when it hit stop loss while deal cancellation option is active, client would feel cheated.
    if ($self->pricing_new and $self->cancellation and $self->stop_loss) {
        return {
            message           => 'deal cancellation set with stop loss',
            message_to_client => $ERROR_MAPPING->{EitherStopLossOrCancel},
            details           => {field => 'stop_loss'},
        };
    }

    return;
}

sub _validate_commission {
    my $self = shift;

    unless (defined $self->commission) {
        return {
            message           => 'multiplier commission not defined for ' . $self->underlying->symbol,
            message_to_client => $ERROR_MAPPING->{InvalidInputAsset},
        };
    }

    return;
}

sub _validate_multiplier_range {
    my $self = shift;

    my $available_multiplier = $self->_multiplier_config->{multiplier_range};
    unless (first { $self->multiplier == $_ } @$available_multiplier) {
        return {
            message           => 'multiplier out of range',
            message_to_client => [$ERROR_MAPPING->{MultiplierOutOfRange}, join(',', @$available_multiplier)],
            details => {field => 'multiplier'},
        };
    }

    return;
}

sub _validate_sell_pnl {
    my $self = shift;

    # To protect against user accidentally closing contract at loss when deal cancellation is active or
    # to protect against race condition around the sell request, we will invalidate sell if pnl is negative when deal cancellation is active.
    # The better option is for the user to cancel the contract and get back the stake.
    if ($self->current_pnl < 0 and $self->is_valid_to_cancel) {
        return {
            message           => 'cancel is better',
            message_to_client => $ERROR_MAPPING->{CancelIsBetter},
        };
    }

    return;
}

has _multiplier_config => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__multiplier_config {
    my $self = shift;

    my $for_date = $self->underlying->for_date;
    my $qc       = BOM::Config::QuantsConfig->new(
        for_date         => $for_date,
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader($for_date),
    );

    return $qc->get_config('multiplier_config', {underlying_symbol => $self->underlying->symbol}) // {};
}

sub _limit_order_args {
    my $self = shift;

    return {
        ask_price       => $self->_user_input_stake,
        multiplier      => $self->multiplier,
        sentiment       => $self->sentiment,
        commission      => $self->commission,
        underlying      => $self->underlying,
        order_precision => Format::Util::Numbers::get_precision_config()->{price}->{$self->currency} // 0,
    };
}

sub _pnl_sign {
    my $self = shift;

    return $self->sentiment eq 'up' ? 1 : -1;
}

has _order => (
    is      => 'ro',
    default => sub { {} },
);

has _formula_args => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_formula_args',
);

sub _build_formula_args {
    my $self = shift;

    # not sure when we will be implementing multiplier for financial instruments,
    # don't over-complicate matters now.
    my $sigma =
          $self->underlying->volatility_surface_type eq 'flat'
        ? $self->volsurface->get_volatility
        : die 'you need to refactor volatility calculation for financial instrument';

    return {
        t => ($self->cancellation_expiry->epoch - $self->date_start->epoch) / (86400 * 365),
        r => 0,
        q => 0,
        mu    => 0,
        sigma => $sigma,
    };
}

sub _spot_proxy {
    return 1;
}

sub _generation_interval_in_years {
    my $self = shift;

    return $self->underlying->generation_interval->seconds / (365 * 86400);
}

sub _barrier_continuity_adjustment {
    my $self = shift;

    return BARRIER_ADJUSTMENT_FACTOR * $self->_formula_args->{sigma} * sqrt($self->_generation_interval_in_years);
}

1;
