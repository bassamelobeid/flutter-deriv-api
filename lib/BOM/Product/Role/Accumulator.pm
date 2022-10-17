package BOM::Product::Role::Accumulator;

use Moose::Role;

with 'BOM::Product::Role::DoubleBarrier', 'BOM::Product::Role::AmericanExpiry' => {-excludes => ['_build_hit_tick']};

use BOM::Product::Exception;
use BOM::Product::Static;
use Format::Util::Numbers qw(financialrounding);
use Scalar::Util::Numeric qw(isint);
use YAML::XS              qw(LoadFile);
use POSIX                 qw(floor ceil);
use List::Util            qw(any min max);
use BOM::Config::Quants   qw(maximum_stake_limit);
use JSON::MaybeXS         qw(decode_json);

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

my $config = {
    tick_size_barrier => LoadFile('/home/git/regentmarkets/bom/config/files/default_tick_size_barrier_accumulator.yml'),
    loss_probability  => LoadFile('/home/git/regentmarkets/bom/config/files/default_loss_probability_accumulator.yml'),
};

=head2 BUILD

Do necessary parameters check here

=cut

sub BUILD {
    my $self = shift;

    unless ($self->growth_rate) {
        BOM::Product::Exception->throw(
            error_code => 'MissingRequiredContractParams',
            error_args => ['growth_rate'],
            details    => {field => 'basis'},
        );
    }

    my $allowable_growth_rate = $self->symbol_config->{growth_rate};
    unless (any { $_ == $self->growth_rate } @$allowable_growth_rate) {
        BOM::Product::Exception->throw(
            error_code => 'InvalidAccumulatorGrowthRate',
            error_args => [$self->growth_rate, $self->symbol_config->{growth_rate}],
            details    => {field => 'basis'},
        );
    }
}

=head2 growth_rate

the rate at which payout grows. 
it can be between 1 to 5 percent
it is stored in decimal presentaion, for example 0.01

=cut

has growth_rate => (
    is      => 'ro',
    default => undef,
);

=head2 growth_frequency

the frequency at which the payout grows
for example 2 means after every two ticks the payout increases

=cut

has growth_frequency => (
    is      => 'ro',
    default => 1,
);

=head2 symbol_config

Symbol config set in BackOffice

=cut

has symbol_config => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 _build_symbol_config 

Initilazing symbol config

=cut

sub _build_symbol_config {
    my $self = shift;

    my $lc          = (defined $self->landing_company and $self->landing_company ne 'virtual') ? $self->landing_company : 'common';
    my $symbol      = $self->underlying->symbol;
    my $all_records = decode_json($self->app_config->get("quants.accumulator.symbol_config.$lc.$symbol"));
    my $key         = _closest_key_to_value($all_records, $self->date_start->epoch);

    return $all_records->{$key};
}

=head2 growth_start_step

the number of tick after which payout starts to grow

=cut

has growth_start_step => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 _build_growth_start_step

fetching the config for growth_start_step

=cut

sub _build_growth_start_step {
    my $self = shift;

    return $self->symbol_config->{growth_start_step};
}

=head2 take_profit

contract is closed when take profit is breached.

a hashref that includes amount and date of take profit order : 
    {
        amount => 100, 
        date => Date::Utility=HASH(...)
    }

=cut

has take_profit => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 _build_take_profit

initializing take_profit

=cut

sub _build_take_profit {
    my $self = shift;

    return undef unless defined $self->_order->{take_profit};

    if ($self->pricing_new) {
        return {
            amount => $self->_order->{take_profit},
            date   => $self->date_pricing,
        };
    }
    return {
        amount => $self->_order->{take_profit}{amount},
        date   => Date::Utility->new($self->_order->{take_profit}{date})};
}

=head2 duration

the duration of contract which be set internally.
No predefined duration from client side.
it is the minimum between :
    - maximum possible ticks for the contract
    - number of ticks on which payout reaches the maximum possible amount
    - number of ticks on which payout reaches take_profit amount

=head2 max_payout

maximum payout that client can win out of a contract

=head2 max_duration

the maximum possible ticks that contract can be running

=head2 basis_spot

the spot that is used for barrier calculation
for a new contract we use current_spot (just to be able to show a pair of barriers in FE if needed).
in other cases bais_spot = previous_spot.
since entry_tick is the first tick of the contract there is no previous spot, so basis_spot = undef

=head2 tick_count_after_entry

number of ticks recieved after entry_tick

=head2 pnl

profit and loss of the contract

=cut 

has [qw(max_duration duration max_payout take_profit tick_count tick_size_barrier basis_spot tick_count_after_entry pnl)] => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 _build_max_duration

initializing max_duration

=cut

sub _build_max_duration {
    my $self = shift;

    my $coefficient = $self->symbol_config->{max_duration_coefficient};
    return floor($coefficient / $config->{loss_probability}{"growthRate_" . $self->growth_rate});
}

=head2 _build_duration

initializing duration

=cut

sub _build_duration {
    my $self = shift;

    my $duration = min($self->tickcount_for($self->max_payout), $self->max_duration);

    #if take_profit is defined, it affects the contract duration.
    if ($self->target_payout) {
        $duration = min($duration, $self->tickcount_for($self->target_payout));
    }

    return $duration . 't';
}

=head2 _build_max_payout

initializing max_payout

=cut

sub _build_max_payout {
    my $self = shift;

    return $self->symbol_config->{max_payout}->{$self->currency};
}

=head2 _build_tick_count

initializing tick_count

=cut

sub _build_tick_count {
    my $self = shift;
    return $self->duration =~ s/\D//r;
}

=head2 _build_tick_count_after_entry

number of ticks recived after entry_tick

=cut 

sub _build_tick_count_after_entry {
    my $self = shift;

    return scalar @{$self->ticks_for_tick_expiry};
}

=head2 ticks_to_expiry

The number of ticks required from contract start time to expiry.

=cut

sub ticks_to_expiry {
    my $self = shift;

    return $self->tick_count;
}

=head2 _build_tick_size_barrier

initializing tick_size_barrier

=cut

sub _build_tick_size_barrier {
    my $self = shift;

    return $config->{tick_size_barrier}{$self->underlying->symbol}{"growthRate_" . $self->growth_rate};
}

=head2 _build_basis_spot

initializing basis_spot

=cut

sub _build_basis_spot {
    my $self = shift;

    return $self->current_spot if $self->pricing_new;

    return ($self->entry_tick and $self->date_pricing->epoch > $self->entry_tick->epoch)
        ? $self->previous_spot_before($self->date_pricing->epoch)
        : undef;
}

=head2 _build_high_barrier

initializing high_barrier

=cut

sub _build_high_barrier {
    my $self = shift;

    return $self->basis_spot ? $self->make_barrier($self->get_high_barrier($self->basis_spot), {barrier_kind => 'high'}) : undef;
}

=head2 get_high_barrier

get a spot and calculate high barrier using tick_size_barrier

=cut

sub get_high_barrier {
    my ($self, $spot) = @_;

    return $spot * (1 + $self->tick_size_barrier);
}

=head2 _build_low_barrier

initializing low_barrier

=cut

sub _build_low_barrier {
    my $self = shift;

    return $self->basis_spot ? $self->make_barrier($self->get_low_barrier($self->basis_spot), {barrier_kind => 'low'}) : undef;
}

=head2 get_low_barrier

get a spot and calculate low barrier using tick_size_barrier

=cut

sub get_low_barrier {
    my ($self, $spot) = @_;

    return $spot * (1 - $self->tick_size_barrier);
}

=head2 _build_pnl

initializing pnl

=cut

sub _build_pnl {
    my $self = shift;

    return financialrounding('price', $self->currency, $self->bid_price - $self->_user_input_stake);
}

override 'shortcode' => sub {
    my $self = shift;

    return join '_',
        (
        uc $self->code,
        uc $self->underlying->symbol,
        financialrounding('price', $self->currency, $self->_user_input_stake),
        $self->growth_start_step, $self->growth_rate, $self->growth_frequency, $self->tick_size_barrier, $self->date_start->epoch,
        );
};

override '_build_ticks_for_tick_expiry' => sub {
    my $self = shift;

    return [] unless $self->entry_tick;

    return $self->_tick_accessor->ticks_in_between_start_limit({
        start_time => $self->entry_tick->epoch + 1,
        limit      => $self->ticks_to_expiry,
    });
};

=head2 bid_price

Bid price which will be saved into sell_price in financial_market_bet table.

=cut

override '_build_bid_price' => sub {
    my $self = shift;

    return $self->sell_price if $self->is_sold;
    return $self->value      if $self->is_expired;

    return $self->calculate_payout($self->tick_count_after_entry);
};

=head2 calculate_payout

get an integer as tickcount and calculate contract value/payout
payout = stake * (1 + growth_rate) ^ tickCount

=cut

sub calculate_payout {
    my ($self, $total_ticks) = @_;

    my $effective_tick_count = $total_ticks - $self->growth_start_step;
    return financialrounding('price', $self->currency, $self->_user_input_stake * (1 + $self->growth_rate)**$effective_tick_count);
}

override '_build_ask_price' => sub {
    my $self = shift;

    return $self->_user_input_stake;
};

=head2 _build_payout

initializing payout

=cut

sub _build_payout {
    return 0;
}

=head2 require_price_adjustment

price adjustment is not needed for accumulator

=cut

sub require_price_adjustment {
    return 0;
}

=head2 app_markup_dollar_amount

set app_markup to zero because it is not allowed for accumulators

=cut

sub app_markup_dollar_amount {
    return 0;
}

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

has _order => (
    is      => 'ro',
    default => sub { {} },
);

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

    my $max_take_profit = $self->max_payout - $self->_user_input_stake;
    if ($take_profit->{amount} > $max_take_profit) {
        return {
            message           => 'take profit too high',
            message_to_client => [$ERROR_MAPPING->{TakeProfitTooHigh}, financialrounding('price', $self->currency, $max_take_profit)],
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

=head2 _validate_maximum_stake

stake can't be greater than maximum stake limit

=cut

sub _validate_maximum_stake {
    my $self = shift;

    my $default_max_stake = maximum_stake_limit($self->currency, $self->landing_company, $self->underlying->market->name, $self->category->code);
    if ($self->_user_input_stake > $default_max_stake) {
        return {
            message           => 'maximum stake limit',
            message_to_client => [$ERROR_MAPPING->{StakeLimitExceeded}, financialrounding('price', $self->currency, $default_max_stake)],
            details           => {field => 'stake'},
        };
    }
    return;
}

=head2 _validation_methods

all validation methods needed for accumulator

=cut

sub _validation_methods {
    my $self = shift;

    my @validation_methods = qw(_validate_offerings
        _validate_input_parameters
        _validate_feed
        validate_take_profit
        _validate_maximum_stake);
    push @validation_methods, qw(_validate_trading_times) unless $self->underlying->always_available;

    return \@validation_methods;
}

=head2 tickcount_for 

number of ticks needed for the contract to reach a payout

payout = stake * (1 + growth_rate) ^ tickCount
=> tickCount = log(payout/stake) / log(1 + growth_rate);

=cut 

sub tickcount_for {
    my ($self, $payout) = @_;

    my $effective_ticks = ceil(log($payout / $self->_user_input_stake) / log(1 + $self->growth_rate));
    #calculate the exact tick considering growth_start_step
    my $tickcount = $effective_ticks + $self->growth_start_step;
    #due to calculation precision there is chance that $effective_ticks will be one unit larger than the actual value
    return $self->calculate_payout($tickcount - 1) >= $payout ? $tickcount - 1 : $tickcount;
}

=head2 target_payout

target_payout = stake + take_profit 

=cut 

sub target_payout {
    my $self = shift;

    return undef unless ($self->take_profit and $self->take_profit->{amount});
    return $self->_user_input_stake + $self->take_profit->{amount};
}

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
        my $higher = $self->get_high_barrier($prev_spot);
        my $lower  = $self->get_low_barrier($prev_spot);

        return $tick if (($tick->quote >= $higher) or ($tick->quote <= $lower));

        $prev_spot = $tick->quote;
    }

    return undef;
}

=head2 _build_close_tick

initializing close_tick attribute

=cut

sub _build_close_tick {
    my $self = shift;

    return $self->hit_tick if $self->hit_tick;

    my $exit_tick = $self->exit_tick;

    return $exit_tick unless $self->is_sold;

    # for contract that is sold at expiry
    return $exit_tick if ($self->sell_time >= $self->date_expiry->epoch);

    # this is sell at market, the contract could be sold on tick at sell_time or the previous tick
    # we use the sell_price to find that exact tick here.
    my $tickcount         = $self->tickcount_for($self->sell_price);
    my @ticks_since_start = @{$self->ticks_for_tick_expiry};
    return $ticks_since_start[$tickcount - 1];
}

=head2 previous_spot_before 

Returns the spot before the specified epoch.

=cut

sub previous_spot_before {
    my ($self, $epoch) = @_;

    confess 'epoch is required' unless $epoch;

    my ($previous_tick) = @{
        $self->_tick_accessor->ticks_in_between_end_limit({
                end_time => $epoch - 1,
                limit    => 1
            })};

    return $previous_tick->quote;
}

=head2 is_valid_to_sell

Checks if the contract is valid to sell back 

=cut

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

    foreach my $method (qw(_validate_trading_times _validate_feed _validate_sell_time)) {
        if (my $error = $self->$method($args)) {
            $self->_add_error($error);
            return 0;
        }
    }
    return 1;
}

=head2 _validate_sell_time

make sure contract is not being sold on entry_tick or before that 
entry_tick is only used for calculating the barriers, the tick after that is when contract actually starts

=cut

sub _validate_sell_time {
    my $self = shift;

    unless ($self->tick_count_after_entry) {
        return {
            message           => 'wait for next tick after entry tick',
            message_to_client => $ERROR_MAPPING->{SellAtEntryTick},
        };
    }
    return;
}

override 'is_after_expiry' => sub {
    my $self = shift;

    return $self->exit_tick ? 1 : 0;
};

=head2 _closest_key_to_value

get a hashref and a value as input.
return the greatest key in the hash which is less or equal to value

=cut

sub _closest_key_to_value {
    my ($hash, $value) = @_;

    return max grep { $_ <= $value } keys %{$hash};
}

1;
