package BOM::Product::Role::Multiplier;

use BOM::Config::Chronicle;
use BOM::Config::Quants qw(get_exchangerates_limit minimum_stake_limit maximum_stake_limit);
use BOM::Config::QuantsConfig;
use BOM::Config::Runtime;
use BOM::Product::Exception;
use BOM::Product::LimitOrder;
use BOM::Product::Utils qw(beautify_stake);
use Date::Utility;
use Format::Util::Numbers qw(financialrounding);
use List::Util            qw(min max first);
use Machine::Epsilon;
use Math::Util::CalculatedValue::Validatable;
use Moose::Role;
use Quant::Framework::EconomicEventCalendar;
use Quant::Framework::Spread::Seasonality;
use Time::Duration::Concise;
use YAML::XS qw(LoadFile);

use constant {
    BARRIER_ADJUSTMENT_FACTOR => 0.5826,
    MIN_COMMISSION_MULTIPLIER => 0.75,
    MAX_COMMISSION_MULTIPLIER => 4,
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
    my $commission;
    if (defined $self->_order->{stop_out} and defined $self->_order->{stop_out}->{commission}) {
        $commission = $self->_order->{stop_out}->{commission};
    } else {
        my $base_commission       = $self->_multiplier_config->{commission};
        my $commission_multiplier = $self->commission_multiplier;

        unless (defined $base_commission and defined $commission_multiplier) {
            $self->_add_error({
                message           => 'multiplier commission not defined for ' . $self->underlying->symbol,
                message_to_client => $ERROR_MAPPING->{InvalidInputAsset},
            });
            $commission = 0;
        } else {
            $commission = $base_commission * $commission_multiplier;
        }
    }

    my $commission_amount = $commission * $self->_user_input_stake * $self->multiplier;
    my $min_commission    = $self->_minimum_main_contract_commission;

    if ($commission_amount < $min_commission) {
        $commission        = $min_commission / ($self->_user_input_stake * $self->multiplier);
        $commission_amount = $min_commission;
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

=head2 next_tick_execution

Next tick execution for multiplier contract.
Will be set by pricer daemon.

=cut

has next_tick_execution => (
    is      => 'ro',
    default => undef,
);

=head2 date_expiry

The expiry time of the contract. Non-binary (multiplier contract), does not have expiries.
But, we need an expiry time for every contract the database. Hence, hard-coding a 100-year expiry time here.

=cut

override '_build_date_expiry' => sub {
    my $self = shift;

    # default to 100 years from now if it is not defined.
    my $expiry = $self->_multiplier_config->{expiry} || '36500d';

    my $date_expiry = $self->date_start->truncate_to_day->plus_time_interval($expiry);

    my $close = $self->trading_calendar->closing_on($self->underlying->exchange, $date_expiry);

    return $close if $close;
    return $self->trading_calendar->trade_date_after($self->underlying->exchange, $date_expiry);
};

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

    # The architecutre now is that we're putting dealing/execution
    # logic in contract creation logic.
    # To cater for next tick execution we had to have these workaround.
    #
    # Basis spot is saved in child table just for the record but not using it for pricing.
    return $self->current_spot if $self->pricing_new;

    if (my $entry_spot = $self->entry_spot) {
        return $entry_spot;
    } else {
        $self->_add_error({
            message           => "Waiting for entry tick [symbol: " . $self->underlying->symbol . "]",
            message_to_client => [$ERROR_MAPPING->{EntryTickMissing}],
        });

        # we had to return a resonable value here so that the current_pnl() calculation is reasonable
        return $self->current_spot;
    }
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
        %{$self->_limit_order_args($order_type)});
}

sub _build_stop_loss {
    my $self = shift;

    return undef unless defined $self->_order->{stop_loss};

    if ($self->pricing_new) {
        return $self->new_order({stop_loss => $self->_order->{stop_loss}});
    }

    my $args = $self->_order->{stop_loss};
    # override basis_spot if it's next tick execution
    $args->{basis_spot} = $self->basis_spot if $self->next_tick_execution;

    return BOM::Product::LimitOrder->new({%$args, %{$self->_limit_order_args('stop_loss')}});
}

sub _build_take_profit {
    my $self = shift;

    return undef unless defined $self->_order->{take_profit};

    if ($self->pricing_new) {
        return $self->new_order({take_profit => $self->_order->{take_profit}});
    }

    my $args = $self->_order->{take_profit};
    # override basis_spot if it's next tick execution
    $args->{basis_spot} = $self->basis_spot if $self->next_tick_execution;

    return BOM::Product::LimitOrder->new({%$args, %{$self->_limit_order_args('take_profit')}});
}

sub _build_stop_out {
    my $self = shift;

    # If it is a new contract, construct stop_out using configs from backoffice
    if ($self->pricing_new) {
        my $stop_out_percentage = $self->stop_out_level;
        my $order_amount        = financialrounding('price', $self->currency, (1 - $stop_out_percentage / 100) * $self->_user_input_stake);

        return $self->new_order({stop_out => $order_amount});
    }

    # if stop out is not defined for non-pricing_new, then we have a problem.
    unless ($self->_order->{stop_out}) {
        BOM::Product::Exception->throw(
            error_code => 'CannotValidateContract',
            details    => {field => ''},
        );
    }

    my $args = $self->_order->{stop_out};
    # override basis_spot if it's next tick execution
    # DO NOT modifty order_date because it will affect contract sell/update.
    $args->{basis_spot} = $self->basis_spot if $self->next_tick_execution;

    return BOM::Product::LimitOrder->new({%$args, %{$self->_limit_order_args('stop_out')}});
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
            my $type = $self->hit_type;

            my $pnl =
                (abs($self->$type->barrier_value - $self->hit_tick->quote) < machine_epsilon())
                ? $self->$type->order_amount
                : $self->_calculate_pnl_at_tick({at_tick => $self->hit_tick});
            $pnl = max($pnl, -$self->_user_input_stake);
            my $value = $self->_user_input_stake + $pnl;
            $self->value(financialrounding('price', $self->currency, $value));
            return 1;
        }
    } elsif (my $exit_tick = $self->exit_tick) {
        # we don't expect a contract to reach date_expiry (except for cryptocurrency which has shorter duration), but we it does, we will need to close
        # it at current tick.
        my $value = $self->_user_input_stake + max($self->_calculate_pnl_at_tick({at_tick => $exit_tick}), -$self->_user_input_stake);
        $self->value(financialrounding('price', $self->currency, $value));
        return 1;
    }

    return 0;
}

override '_build_exit_tick' => sub {
    my $self = shift;

    return if $self->date_pricing->epoch <= $self->date_expiry->epoch;
    return $self->underlying->tick_at($self->date_expiry->epoch);
};

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
    return undef unless $self->entry_tick;
    # we can't really combined the search for stop out and take profit because
    # we can potentially look at different periods once we allow changing of take profit
    # when contract is opened.
    my $end_time;
    if ($self->sell_time) {
        $end_time = Date::Utility->new($self->sell_time)->epoch;
    } else {
        $end_time = $self->date_pricing->is_before($self->date_expiry) ? $self->date_pricing->epoch : $self->date_expiry->epoch;
    }

    my $stop_out_tick = $self->_get_breaching_tick(max($self->stop_out->order_date->epoch, $self->entry_tick->epoch),
        $end_time, {$self->stop_out_side => $self->stop_out->barrier_value});
    my $take_profit_tick =
        ($self->take_profit and defined $self->take_profit->barrier_value)
        ? $self->_get_breaching_tick(max($self->take_profit->order_date->epoch, $self->entry_tick->epoch),
        $end_time, {$self->take_profit_side => $self->take_profit->barrier_value})
        : undef;
    my $stop_loss_tick =
        ($self->stop_loss and defined $self->stop_loss->barrier_value)
        ? $self->_get_breaching_tick(max($self->stop_loss->order_date->epoch, $self->entry_tick->epoch),
        $end_time, {$self->stop_loss_side => $self->stop_loss->barrier_value})
        : undef;

    # there's a small chance both stop out and take profit can happen (mostly due to delay in sell)
    # let's not take any chances.
    if (($stop_loss_tick or $stop_out_tick) and $take_profit_tick) {
        # stop_loss_tick should always have higher priority over stop_out if both were breached
        if ($stop_loss_tick and $stop_loss_tick->epoch < $take_profit_tick->epoch) {
            $self->hit_type('stop_loss');
            return $stop_loss_tick;
        } elsif ($stop_out_tick and $stop_out_tick->epoch < $take_profit_tick->epoch) {
            $self->hit_type('stop_out');
            return $stop_out_tick;
        } else {
            $self->hit_type('take_profit');
            return $take_profit_tick;
        }
    } elsif ($stop_out_tick) {
        $self->hit_type('stop_out');
        return $stop_out_tick;
    } elsif ($take_profit_tick) {
        $self->hit_type('take_profit');
        return $take_profit_tick;
    } elsif ($stop_loss_tick) {
        $self->hit_type('stop_loss');
        return $stop_loss_tick;
    }

    return undef;
}

=head2 hit_type

Did the contract thit take profit, stop loss or stop out.

=cut

has hit_type => (
    is      => 'rw',
    default => undef,
);

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
    my $nth_tick   = $args->{at_tick} or die 'calculating pnl without a reference tick';
    my $commission = $self->commission // 0;

    my $main_pnl =
        $self->_user_input_stake * ($self->_pnl_sign * ($nth_tick->quote - $self->basis_spot) / $self->basis_spot - $commission) * $self->multiplier;

    return financialrounding('price', $self->currency, $main_pnl);
}

=head2 current_pnl

Current PnL of the contract. This is the pnl of the main contract (does not include cost of risk management E.g. deal protection or deal cancellation) and is used deal cancellation.

If PnL is > 0, then you can close the contract, else cancelling is a better option

=cut

sub current_pnl {
    my $self = shift;

    return '0.00' if $self->pricing_new;

    return $self->_calculate_pnl_at_tick({at_tick => $self->hit_tick}) if $self->hit_tick;
    return $self->_calculate_pnl_at_tick({at_tick => $self->current_tick});
}

=head2 total_pnl

The pnl of the contract (includes cost of risk mangement).

=cut

sub total_pnl {
    my $self = shift;

    return '0.00' if $self->pricing_new;

    my $total_pnl = $self->current_pnl - $self->cancellation_price;

    return financialrounding('price', $self->currency, $total_pnl);
}

=head2 bid_price

Bid price which will be saved into sell_price in financial_market_bet table.

=cut

override '_build_bid_price' => sub {
    my $self = shift;

    return $self->cancel_price if $self->is_cancelled;
    return $self->sell_price   if $self->is_sold;
    return $self->value        if $self->is_expired;
    return max(0, $self->_user_input_stake + $self->current_pnl());
};

override '_build_ask_price' => sub {
    my $self = shift;

    return $self->_user_input_stake + $self->cancellation_price;
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

override _build_entry_tick => sub {
    my $self = shift;

    return undef if $self->pricing_new;

    # for existing open positions on synthetic index, the pricing on proposal open contract is using shortcode to price.
    # The old shortcode will not have a _N1 suffix,
    # so they are all spot execution
    #
    # Since we only store spot price in child table,
    # we need a way to get the tick using the spot price.
    # So we will get the tick and compare it's spot price.
    # It's not a clean nor elegant way.
    # But, it's the only way to get the tick.
    if ($self->underlying->market->name eq 'synthetic_index') {
        unless ($self->next_tick_execution) {
            my $basis_spot    = $self->_order->{stop_out}->{basis_spot};
            my $tick_at_start = $self->underlying->tick_at($self->date_start->epoch, {allow_inconsistent => 1});
            return $tick_at_start if abs($tick_at_start->quote - $basis_spot) < machine_epsilon();

            # if it doesn't match, it has to be the tick before the start time
            # due to feed distribution latency
            return $self->underlying->tick_at($self->date_start->epoch - 1, {allow_inconsistent => 1});
        }
    }

    # else, we will continue to next tick execution
    if (my $tick = $self->underlying->next_tick_after($self->date_start->epoch)) {
        return $tick;
    } else {
        $self->_add_error({
            message           => "Waiting for entry tick [symbol: " . $self->underlying->symbol . "]",
            message_to_client => [$ERROR_MAPPING->{EntryTickMissing}],
        });
        return undef;
    }
};

override 'shortcode' => sub {
    my $self = shift;

    my $shortcode = join '_',
        (
        uc $self->code,
        uc $self->underlying->symbol,
        financialrounding('price', $self->currency, $self->_user_input_stake),
        $self->multiplier,
        $self->date_start->epoch,
        $self->date_expiry->epoch,
        $self->cancellation, financialrounding('price', $self->currency, $self->cancellation_tp),
        );

    $shortcode = join '_', $shortcode, 'N' . $self->next_tick_execution if $self->next_tick_execution;

    return $shortcode;

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

    # contract cannot be sold before it's even started
    if (!$self->entry_tick) {
        $self->_add_error({
            message           => "Waiting for entry tick [symbol: " . $self->underlying->symbol . "]",
            message_to_client => [$ERROR_MAPPING->{EntryTickMissing}],
            details           => {},
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

This is formatted in a way that it can be directly put into PRICER_ARGS.

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

    if ($self->cancellation) {
        push @available_orders, ('cancellation', ['price', $self->cancellation_price]);
    }

    return \@available_orders;
}

sub _extract_details {
    my ($self, $order_object) = @_;

    my $order_amount = $order_object->order_amount ? $order_object->order_amount + 0 : undef;
    # this details needs to in the following order (sort qw(order_type order_amount basis_spot order_date)). Do not change the order!
    return [
        'basis_spot',                                               $order_object->basis_spot + 0, 'order_amount',
        financialrounding('price', $self->currency, $order_amount), 'order_date',                  int($order_object->order_date->epoch),
        'order_type',                                               $order_object->order_type,     'commission',
        $order_object->commission,
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

has close_tick => (
    is         => 'ro',
    lazy_build => 1
);

sub _build_close_tick {
    my $self = shift;

    return $self->hit_tick if $self->hit_tick;

    my $exit_tick = $self->exit_tick;

    # right at the date_expiry and contract is not sold
    return $exit_tick if $exit_tick and not $self->is_sold;

    return undef unless $self->is_sold;

    # for contract that is sold at expiry
    return $exit_tick if ($self->sell_time >= $self->date_expiry->epoch);

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

=head2 cancellation_cv

We allow client to purchase deal cancellation on top of their main contract
at a premium.

returns <Math::Util::CalculatedValue::Validatable>

=cut

sub cancellation_cv {
    my $self = shift;

    # if there's no cancellation request, do not charge
    unless ($self->cancellation) {
        return Math::Util::CalculatedValue::Validatable->new({
            name        => 'cancellation_ask',
            description => 'ask price for deal cancellation',
            set_by      => __PACKAGE__,
            base_amount => 0,
        });
    }

    my $backprice = $self->underlying->for_date ? 1 : 0;
    my $cancellation_price =
        ($self->_order->{cancellation} and $self->_order->{cancellation}->{price}) ? $self->_order->{cancellation}->{price} : undef;

    # for backprice, we want the breakdown of deal cancellation calculation
    if (not $backprice and defined $cancellation_price) {
        return Math::Util::CalculatedValue::Validatable->new({
            name        => 'cancellation_ask',
            description => 'ask price for deal cancellation',
            set_by      => __PACKAGE__,
            base_amount => $cancellation_price,
        });
    }

    my $cost_cv = Math::Util::CalculatedValue::Validatable->new({
        name        => 'cancellation_ask',
        description => 'ask price for deal cancellation',
        set_by      => __PACKAGE__,
        minimum     => $self->_minimum_cancellation_commission,
        base_amount => 0,
    });

    $cost_cv->include_adjustment('reset', $self->_standard_barrier_option);

    my $volume_cv = Math::Util::CalculatedValue::Validatable->new({
            name        => 'volume',
            description => 'stake x multiplier',
            set_by      => __PACKAGE__,
            base_amount => $self->_user_input_stake * $self->multiplier,

    });

    $cost_cv->include_adjustment('multiply', $volume_cv);

    my $dc_commission = $self->_multiplier_config->{cancellation_commission} * $self->dc_commission_multiplier;

    my $comm_multiplier_cv = Math::Util::CalculatedValue::Validatable->new({
        name        => 'commission_multiplier',
        description => 'commission markup on the cost',
        set_by      => __PACKAGE__,
        base_amount => 1 + $dc_commission,
    });

    $cost_cv->include_adjustment('multiply', $comm_multiplier_cv);

    return $cost_cv;
}

sub cancellation_price {
    my $self = shift;

    return financialrounding('price', $self->currency, $self->cancellation_cv->amount);
}

sub stop_out_level {
    my $self = shift;

    my $stop_out_config = $self->_multiplier_config->{stop_out_level};

    # Historically stop_out_level is just an integer. We need to introduce stop_out_level for each multiplier when we introduce crash/boom indices
    # on multiplier
    return $stop_out_config unless ref $stop_out_config;
    my $level = $stop_out_config->{$self->multiplier};

    unless (defined $level) {
        my $available_multiplier = $self->_multiplier_config->{multiplier_range};
        $self->_add_error({
            message           => 'stop out level undefined for multiplier',
            message_to_client => [$ERROR_MAPPING->{MultiplierOutOfRange}, join(',', @$available_multiplier)],
            details           => {field => 'multiplier'},
        });

        return 0;
    }

    return $level;
}

around maximum_feed_delay_seconds => sub {
    my $orig = shift;
    my $self = shift;

    return $self->$orig() if $self->underlying->market->name ne 'synthetic_index';

    # multipliers on synthetic indices will need to have much stricter checks on feed outage.
    # setting the threshold at twice the generation interval.
    my $delay_threshold = $self->underlying->generation_interval->seconds * 2;

    return $delay_threshold;
};

### PRIVATE METHODS ###

sub _validation_methods {
    # For multiplier contract we will validation:
    # - offerings (if contract is disabled from backoffice)
    # - start time (if start time is in the past or in the future)
    # - trading times (if market is open)
    # - feed (if feed is too old)
    return [
        qw(_validate_offerings _validate_input_parameters _validate_trading_times _validate_blackout_start _validate_feed _validate_commission _validate_multiplier_range _validate_maximum_stake _validate_orders _validate_cancellation)
    ];
}

sub _validate_blackout_start {
    my $self = shift;

    # Due to uncertainty around volsurface rollover time, we want to disable buy 5 minutes before rollover and 30 minutes after rollover.
    # Only applicable for forex
    return if $self->underlying->market->name ne 'forex';

    my $rollover       = $self->volsurface->rollover_date($self->date_start);
    my $blackout_start = $rollover->minus_time_interval('5m');
    my $blackout_end   = $rollover->plus_time_interval('30m');

    if ($self->date_start->is_after($blackout_start) and $self->date_start->is_before($blackout_end)) {
        return {
            message           => 'multiplier option blackout period during volsurface rollover',
            message_to_client => [$ERROR_MAPPING->{TradingNotAvailable}, $blackout_start->time_hhmmss, $blackout_end->time_hhmmss],
            details           => {field => 'date_start'},
        };
    }

    return;
}

sub _validate_cancellation {
    my $self = shift;

    my $app_config = BOM::Config::Runtime->instance->app_config;

    my $market = $self->underlying->market->name;

    unless ($app_config->quants->suspend_deal_cancellation->can($market)) {
        return {
            message           => 'deal cancellation suspension config not set',
            message_to_client => $ERROR_MAPPING->{DealCancellationPurchaseSuspended},
            details           => {field => 'cancellation'},
        };
    }

    if ($app_config->quants->suspend_deal_cancellation->$market and $self->cancellation) {
        return {
            message           => 'deal cancellation suspended',
            message_to_client => $ERROR_MAPPING->{DealCancellationPurchaseSuspended},
            details           => {field => 'cancellation'},
        };
    }

    return unless $self->cancellation;

    # deal cancellation is not offered to crash/boom and step indices.
    if (   $self->underlying->submarket->name eq 'crash_index'
        or $self->underlying->submarket->name eq 'step_index'
        or $self->underlying->submarket->name eq 'jump_index'
        or $self->underlying->market->name eq 'cryptocurrency')
    {
        return {
            message           => 'deal cancellation not available',
            message_to_client => $ERROR_MAPPING->{DealCancellationNotAvailable},
            details           => {field => 'cancellation'},
        };
    }

    my $available_range       = $self->_multiplier_config->{cancellation_duration_range};
    my $cancellation_interval = Time::Duration::Concise->new(interval => $self->cancellation);

    unless (grep { $cancellation_interval->seconds == Time::Duration::Concise->new(interval => $_)->seconds } @$available_range) {
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

    my $cancellation_blackout_start = 21;
    if ($self->underlying->market->name eq 'forex' and $self->date_start->hour >= $cancellation_blackout_start) {
        my $sod = $self->date_start->truncate_to_day;
        return {
            message           => 'deal cancellation blackout period',
            message_to_client => [
                $ERROR_MAPPING->{DealCancellationBlackout}, $sod->plus_time_interval($cancellation_blackout_start . 'h')->datetime,
                $sod->plus_time_interval('23h59m59s')->datetime
            ],
            details => {field => 'cancellation'},
        };
    }

    # with the Deal Cancellation Tool added we have to make sure contract cancellation is within the available_range
    my $cancellation = $cancellation_interval->minutes;
    my $custom_deal_cancellation =
        $self->_quants_config->custom_deal_cancellation($self->underlying->symbol, $self->landing_company, $self->date_pricing->epoch);
    if ($custom_deal_cancellation) {
        if ((not grep { /$cancellation/ } @$custom_deal_cancellation) or $custom_deal_cancellation eq []) {
            return {
                message           => 'deal cancellation not available',
                message_to_client => $ERROR_MAPPING->{DealCancellationNotAvailable},
                details           => {field => 'cancellation'},
            };
        }
    }

    return;
}

sub _validate_orders {
    my $self = shift;

    # validate stop out order
    if ($self->stop_out and not $self->stop_out->is_valid($self->current_pnl, $self->currency, $self->pricing_new)) {
        return $self->stop_out->validation_error;
    }

    # validate take profit order
    if ($self->take_profit) {
        if ($self->pricing_new and $self->cancellation) {
            return {
                message           => 'deal cancellation set with take profit',
                message_to_client => $ERROR_MAPPING->{EitherTakeProfitOrCancel},
                details           => {field => 'deal_cancellation'},
            };
        }

        if (not $self->take_profit->is_valid($self->total_pnl, $self->currency, $self->pricing_new)) {
            return $self->take_profit->validation_error;
        }
    }

    # validate stop loss order
    if ($self->stop_loss) {
        if ($self->pricing_new and $self->cancellation) {
            return {
                message           => 'deal cancellation set with stop loss',
                message_to_client => $ERROR_MAPPING->{EitherStopLossOrCancel},
                details           => {field => 'deal_cancellation'},
            };
        }

        my $pnl = $self->pricing_new ? -1 * $self->commission_amount : $self->total_pnl;
        if (not $self->stop_loss->is_valid($pnl, $self->currency, $self->pricing_new, $self->stop_out_level)) {
            return $self->stop_loss->validation_error;
        }
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

    my $custom_range = $self->_get_valid_custom_multiplier_range();
    my @available_multiplier =
        grep { (not defined $custom_range->{min} or $_ >= $custom_range->{min}) and (not defined $custom_range->{max} or $_ <= $custom_range->{max}) }
        $self->_multiplier_config->{multiplier_range}->@*;
    unless (first { $self->multiplier == $_ } @available_multiplier) {
        return {
            message           => 'multiplier out of range',
            message_to_client => @available_multiplier
            ? [$ERROR_MAPPING->{MultiplierOutOfRange}, join(',', @available_multiplier)]
            : [$ERROR_MAPPING->{MultiplierRangeDisabled}],
            details => {field => 'multiplier'},
        };
    }

    return;
}

sub _validate_maximum_stake {
    my $self = shift;

    if ($self->_user_input_stake > $self->max_stake) {
        my $display_name = $self->underlying->display_name;
        return {
            message           => 'maximum stake limit',
            message_to_client => $self->max_stake
            ? [$ERROR_MAPPING->{StakeLimitExceeded},          financialrounding('price', $self->currency, $self->max_stake)]
            : [$ERROR_MAPPING->{TradingMultiplierIsDisabled}, $display_name],
            details => {field => 'stake'},
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

has _quants_config => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__quants_config {
    my $self = shift;

    my $for_date = $self->underlying->for_date;
    my $qc       = BOM::Config::QuantsConfig->new(
        for_date         => $for_date,
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader($for_date),
    );

    return $qc;
}

has _multiplier_config => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__multiplier_config {
    my $self = shift;

    my $config = $self->_quants_config->get_multiplier_config($self->landing_company, $self->underlying->symbol);

    return $config if $config && %$config;

    $self->_add_error({
        message           => 'multiplier config undefined for ' . $self->underlying->symbol,
        message_to_client => $ERROR_MAPPING->{InvalidInputAsset},
    });

    # return config for R_100 to avoid warnings but contract will not go through because of validation error
    return $self->_quants_config->get_multiplier_config('common', 'R_100');
}

has _custom_commission_adjustment => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__custom_commission_adjustment {
    my $self = shift;

    my $custom = $self->_quants_config->get_config('custom_multiplier_commission', +{underlying_symbol => $self->underlying->symbol});
    # multiplier commission is presented to client at purchase time. Hence, we're only applying this adjustment at buy (not sell).
    my $epoch = $self->date_start->epoch;

    return [grep { $epoch >= Date::Utility->new($_->{start_time})->epoch && $epoch <= Date::Utility->new($_->{end_time})->epoch } @$custom];
}

sub _get_valid_custom_commission_adjustment {
    my $self = shift;

    my @commission_adj;
    my @dc_commission;
    foreach my $custom (@{$self->_custom_commission_adjustment}) {
        my $min_multiplier = $custom->{min_multiplier};
        my $max_multiplier = $custom->{max_multiplier};

        # notthing to apply if either min or max is defined.
        next if (defined $min_multiplier xor defined $max_multiplier);

        my $valid_range = ((not defined $min_multiplier or $self->multiplier >= $min_multiplier)
                and (not defined $max_multiplier or $self->multiplier <= $max_multiplier)) ? 1 : 0;

        if ($valid_range) {
            push @commission_adj, $custom->{commission_adjustment} if defined $custom->{commission_adjustment};
            push @dc_commission,  $custom->{dc_commission}         if defined $custom->{dc_commission};
        }
    }

    return {
        commission_adj => max(@commission_adj),
        dc_commission  => max(@dc_commission),
    };
}

=head2 _get_valid_custom_multiplier_range

Custom multiplier minimum and maximum range can be set in the backoffice.

Return a hash reference of 'min' and 'max' if configuration matches.

=cut

sub _get_valid_custom_multiplier_range {
    my $self = shift;

    my @max_range;
    my @min_range;
    foreach my $custom (grep { not defined $_->{commission_adjustment} and not defined $_->{dc_commission} } $self->_custom_commission_adjustment->@*)
    {
        push @min_range, $custom->{min_multiplier} if (defined $custom->{min_multiplier});
        push @max_range, $custom->{max_multiplier} if (defined $custom->{max_multiplier});
    }

    return {
        min => max(@min_range),
        max => min(@max_range),
    };
}

sub _limit_order_args {
    my ($self, $order_type) = @_;

    return {
        stake => $self->_user_input_stake,
        $order_type ne 'stop_out' ? (cancellation_price => $self->cancellation_price) : (),
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

    return {
        t     => ($self->cancellation_expiry->epoch - $self->date_start->epoch) / (86400 * 365),
        r     => 0,
        q     => 0,
        mu    => 0,
        sigma => $self->pricing_vol,
    };
}

override 'pricing_vol' => sub {
    my $self = shift;

    # currently, only synthetic, forex and cryptocurrency.
    my $sigma;
    my $market = $self->underlying->market->name;
    if ($market eq 'synthetic_index') {
        $sigma = $self->volsurface->get_volatility;
    } elsif ($market eq 'forex') {
        $sigma = $self->empirical_volsurface->get_volatility({
            from  => $self->date_start,
            to    => $self->cancellation_expiry,
            delta => 50,
            ticks => $self->ticks_for_short_term_volatility_calculation,
        });
    } elsif ($market eq 'cryptocurrency') {
        $sigma = 0.20;    # flat 20% for crypto for compatibility sake. We're not offerings DC or DP on it.
    } else {
        die 'get_volatility for unknown market ' . $market;
    }

    return $sigma;
};

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

=head2 min_stake

Minimum allowable stake to buy a contract

=head2 max_stake

Maximum allowable stake to buy a contract

=cut

has [qw(min_stake max_stake)] => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 _build_min_stake

Initialize minimum allowable stake to buy a contract

=cut

sub _build_min_stake {
    my $self = shift;

    # Couldn't find any formula defining min_stake for Multiplier
    # For now, use only the default value from quants config file
    my $default_min_stake = minimum_stake_limit($self->currency, $self->landing_company, $self->underlying->market->name, $self->category->code);
    my $min_stake         = beautify_stake($default_min_stake, $self->currency, 1);

    return min($min_stake, $self->max_stake);
}

=head2 _build_max_stake

Calculate maximum allowable stake to buy a contract

=cut

sub _build_max_stake {
    my $self                 = shift;
    my $market               = $self->underlying->market->name;
    my $symbol               = $self->underlying->symbol;
    my $custom_volume_limits = $self->risk_profile->raw_custom_volume_limits;

    my @risk_profiles;
    push @risk_profiles, $custom_volume_limits->{markets}{$market}{risk_profile};
    push @risk_profiles, $custom_volume_limits->{symbols}{$symbol}{risk_profile};
    if (!$risk_profiles[0] && !$risk_profiles[1]) {
        push @risk_profiles, $self->market->{risk_profile};
    }

    my $default_max_stake              = maximum_stake_limit($self->currency, $self->landing_company, $market, $self->category->code);
    my $risk_profile_limit_definitions = BOM::Config::quants()->{risk_profile};
    my @defined_risk_profiles          = grep { defined $_ } @risk_profiles;
    my @stake_limits =
        map { get_exchangerates_limit($risk_profile_limit_definitions->{$_}{multiplier}{$self->currency}, $self->currency) } @defined_risk_profiles;
    my $max_stake = min($default_max_stake, @stake_limits);

    return beautify_stake($max_stake, $self->currency);
}

=head2 _minimum_main_contract_commission

Minimum commission for the main contract.
Commission is relative to minimum stake defined in quants config.

=head2 _minimum_cancellation_commission

Minimum commission for deal cancellation of the contract.
Commission is relative to minimum stake defined in quants config.

=cut

sub _minimum_main_contract_commission {
    my $self = shift;

    return $self->min_stake * 0.02;
}

sub _minimum_cancellation_commission {
    my $self = shift;

    return $self->min_stake * 0.01;
}

=head2 commission_multiplier

A factor used to scale commission

=cut

sub commission_multiplier {
    my $self = shift;

    # we do apply specific adjustment to forex commission
    my $market = $self->underlying->market->name;

    my $ee_multiplier          = 1;
    my $seasonality_multiplier = 1;

    if ($market ne 'synthetic_index') {
        $ee_multiplier = $self->_get_economic_event_commission_multiplier();
        # Currently the multiplier for economic event is hard-coded to 3. In the future, this value might be configurable from the
        # backoffice tool.
        $seasonality_multiplier = Quant::Framework::Spread::Seasonality->new->get_spread_seasonality($self->underlying->symbol, $self->date_start);

        unless (defined $seasonality_multiplier) {
            $self->_add_error({
                message           => 'spread seasonality not defined for ' . $self->underlying->symbol,
                message_to_client => $ERROR_MAPPING->{InvalidInputAsset},
            });
            # setting it max commission multiplier
            $seasonality_multiplier = MAX_COMMISSION_MULTIPLIER;
        }
    }

    my $custom_commission            = $self->_get_valid_custom_commission_adjustment;
    my $custom_commission_multiplier = $custom_commission->{commission_adj} // 1.0;

    my $comm_multiplier = max($ee_multiplier, $seasonality_multiplier, $custom_commission_multiplier);

    return max(MIN_COMMISSION_MULTIPLIER, min(MAX_COMMISSION_MULTIPLIER, $comm_multiplier));
}

=head2 dc_commission_multiplier

A factor used to scale deal cancellation commission.

=cut

sub dc_commission_multiplier {
    my $self = shift;

    my $custom_commission        = $self->_get_valid_custom_commission_adjustment;
    my $dc_commission_multiplier = $custom_commission->{dc_commission} // 1.0;

    return max(MIN_COMMISSION_MULTIPLIER, min(MAX_COMMISSION_MULTIPLIER, $dc_commission_multiplier));

}

=head2 _get_economic_event_commission_mutliplier

Economic event multiplier

=cut

my $forex_source = {
    EUR => 1,
    USD => 1,
    GBP => 1,
    CAD => 1,
    AUD => 1,
    JPY => 1,
};
my %basket_source_currency = (
    WLDUSD => $forex_source,
    WLDAUD => $forex_source,
    WLDEUR => $forex_source,
    WLDGBP => $forex_source,
    WLDXAU => {
        EUR => 1,
        USD => 1,
        GBP => 1,
        AUD => 1,
        JPY => 1,
    },
);
my %crypto_source_currency = (
    'cryBTCUSD' => $forex_source,
    'cryETHUSD' => $forex_source,
);

sub _get_economic_event_commission_multiplier {
    my $self = shift;

    my $for_date    = $self->underlying->for_date;
    my $ee_calendar = Quant::Framework::EconomicEventCalendar->new(chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader($for_date));
    my @high_impact_events = grep { $_->{impact} == 5 } @{
        $ee_calendar->get_latest_events_for_period({
                from => $self->date_start->minus_time_interval('5m'),
                to   => $self->date_start->plus_time_interval('5m')
            },
            $for_date
        )};

    my $ee_multiplier = 0;
    if (@high_impact_events) {
        my $currencies;
        if ($self->underlying->submarket->name =~ /^(?:forex_basket|commodity_basket)$/) {
            $currencies = $basket_source_currency{$self->underlying->symbol};
        } elsif ($self->underlying->market->name eq 'cryptocurrency') {
            $currencies = $crypto_source_currency{$self->underlying->symbol};
        } else {
            $currencies = {
                USD                                       => 1,
                $self->underlying->asset_symbol           => 1,
                $self->underlying->quoted_currency_symbol => 1
            };
        }

        for my $event (@high_impact_events) {
            if (exists $currencies->{$event->{symbol}}) {
                $ee_multiplier = 3;
            }
        }
    }

    return $ee_multiplier;
}

1;
