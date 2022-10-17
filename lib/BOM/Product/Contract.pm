package BOM::Product::Contract;

use strict;
use warnings;

=head1 NAME

BOM::Product::Contract - represents a contract object for a single bet

=head1 SYNOPSIS

    use feature qw(say);
    use BOM::Product::ContractFactory qw(produce_contract);
    # Create a simple contract
    my $contract = produce_contract({
        bet_type => 'CALLE',
        duration => '5t',
    });
    # Show the current prices (as of now, since an explicit pricing date is not provided)
    say "Bid for CALLE:  " . $contract->bid_price;
    say "Ask for CALLE:  " . $contract->ask_price;
    # Get the contract with the opposite bet type, in this case a PUT
    my $opposite = $contract->opposite_contract;
    say "Bid for PUT:    " . $opposite->bid_price;
    say "Ask for PUT:    " . $opposite->ask_price;

=head1 DESCRIPTION

This class is the base definition for all our contract types. It provides behaviour common to all contracts,
and defines the standard API for interacting with those contracts.

=cut

use Moose;
extends 'Finance::Contract';

require UNIVERSAL::require;

use MooseX::Role::Validatable::Error;
use Time::HiRes  qw(time);
use List::Util   qw(min max first);
use Scalar::Util qw(looks_like_number);
use Math::Util::CalculatedValue::Validatable;
use Date::Utility;
use Time::Duration::Concise;
use Format::Util::Numbers qw/formatnumber/;
use POSIX                 qw(ceil);
use IO::Socket::IP;
use Syntax::Keyword::Try;
use Encode;

use Quant::Framework;
use Quant::Framework::VolSurface::Utils;
use Quant::Framework::EconomicEventCalendar;
use Postgres::FeedDB::Spot::Tick;

use BOM::Config::Chronicle;
use BOM::Config::Runtime;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Market::RedisTickAccessor;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Platform::RiskProfile;
use BOM::Product::Types;
use BOM::Product::ContractValidator;
use BOM::Product::ContractPricer;
use BOM::Product::Static;
use BOM::Product::Exception;
use Finance::Contract::Longcode qw(shortcode_to_longcode shortcode_to_parameters);

use BOM::Product::Pricing::Engine::Intraday::Forex;
use BOM::Product::Pricing::Engine::Intraday::Index;
use BOM::Product::Pricing::Engine::VannaVolga::Calibrated;
use BOM::Product::Pricing::Greeks::BlackScholes;

use constant {
    MAX_DURATION => 60 * 60 * 24 * 365 * 2    #2 years in seconds
};

my $ERROR_MAPPING   = BOM::Product::Static::get_error_mapping();
my $GENERIC_MAPPING = BOM::Product::Static::get_generic_mapping();

=head1 ATTRIBUTES - Construction

These are the parameters we expect to be passed when constructing a new contract.
These would be passed to L<BOM::Product::ContractFactory/produce_contract>.

=cut

=head2 underlying

The underlying asset, as a L<Finance::Underlying> instance.

=cut

has underlying => (
    is      => 'ro',
    isa     => 'underlying_object',
    coerce  => 1,
    handles => [qw(market pip_size)],
);

=head2 is_cancelled

By default, contract cannot be cancelled unless specified

=cut

sub is_cancelled {
    return 0;
}

#overriding Financial::Contract fields
sub absolute_barrier_multiplier {
    my $self = shift;
    return $self->underlying->market->absolute_barrier_multiplier;
}

sub supplied_barrier_type {
    my $self = shift;

    if ($self->two_barriers) {
        # die here to prevent exception thrown later in pip sizing non interger barrier.
        BOM::Product::Exception->throw(
            error_code => 'InvalidBarrierDifferentType',
            details    => {field => 'barrier2'},
        ) if $self->high_barrier->supplied_type ne $self->low_barrier->supplied_type;
        return $self->high_barrier->supplied_type;
    }
    return $self->barrier->supplied_type;
}

=head1 ATTRIBUTES - Other

=cut

#expiry_daily - Does this bet expire at close of the exchange?
has is_intraday => (
    is         => 'ro',
    lazy_build => 1,
);

has value => (
    is       => 'rw',
    init_arg => undef,
    isa      => 'Num',
    default  => 0,
);

has [qw(entry_tick current_tick)] => (
    is         => 'ro',
    lazy_build => 1,
);

has current_spot => (
    is         => 'rw',
    isa        => 'Maybe[PositiveNum]',
    lazy_build => 1,
);

has build_parameters => (
    is  => 'ro',
    isa => 'HashRef',
    # Required until it goes away entirely.
    required => 1,
);

has trading_calendar => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_trading_calendar',
);

=head2 uses_barrier

 Indicates if the contract uses barriers or not.  Used to send undef as the barrier via the api if false.

 Overridden in the contract classes for those that do not use barriers.

=cut

has uses_barrier => (
    is      => 'ro',
    isa     => 'Bool',
    default => 1,
);

sub _build_trading_calendar {
    my $self = shift;

    my $for_date = $self->underlying->for_date;

    return Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader($for_date), $for_date);
}

has [qw(opposite_contract opposite_contract_for_sale)] => (
    is         => 'ro',
    isa        => 'BOM::Product::Contract',
    lazy_build => 1
);

has is_sold => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0
);

has is_valid_exit_tick => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0
);

has risk_profile => (
    is         => 'ro',
    lazy_build => 1,
    init_arg   => undef,
);

has app_config => (
    is         => 'ro',
    lazy_build => 1,
);

# pricing_spot - The spot used in pricing.
has pricing_spot => (
    is         => 'ro',
    lazy_build => 1,
);

has exit_tick => (
    is         => 'ro',
    lazy_build => 1,
);

has date_expiry => (
    is         => 'rw',
    lazy_build => 1,
);

# to be used for logic related to early sell especially tick related code.
has [qw(sell_time sell_price)] => (
    is => 'ro',
);

has primary_validation_error => (
    is       => 'rw',
    init_arg => undef,
);

has apply_market_inefficient_limit => (
    is         => 'ro',
    lazy_build => 1,
);

# We can't import the Factory directly as that goes circular.
# On the other hand, we want some extra info which only
# becomes available here. So, require the Factory to give us
# a coderef for how we make more of ourselves.
# This should also make it more annoying for people to call the
# constructor directly.. which we hope they will not do.
has _produce_contract_ref => (
    is       => 'ro',
    isa      => 'CodeRef',
    required => 1,
);

has _applicable_economic_events => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_applicable_economic_events',
);

has _basis_tick => (
    is         => 'ro',
    isa        => 'Postgres::FeedDB::Spot::Tick',
    lazy_build => 1,
    builder    => '_build_basis_tick',
);

# ATTRIBUTES - Internal

# Internal hashref of attributes that will be passed to the pricing engine.
has _pricing_args => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

=head1 METHODS - Boolean checks

=cut

=head2 is_after_expiry

This check if the contract already passes the expiry times

For tick expiry contract, there is no expiry time, so it will check again the exit tick
For other contracts, it will check the remaining time of the contract to expiry.

=cut

sub is_after_expiry {
    my $self = shift;

    if ($self->tick_expiry) {
        # We've expired if we have an exit tick...
        return 1 if $self->exit_tick;
        # ... or if we're past our predefined max contract duration for tick trades
        return 1 if $self->date_pricing->epoch - $self->date_start->epoch > $self->_max_tick_expiry_duration->seconds;
        # otherwise, we're still active
        return 0;
    }

    # Delegate to the same method in L<Finance::Contract>
    return $self->next::method;
}

=head2 is_after_settlement

This check if the contract already passes the settlement time

For tick expiry contract, it can expires when a certain number of ticks is received or it already passes the max_tick_expiry_duration.
For other contracts, it can expires when current time has past a pre-determined settelement time.

=cut

sub is_after_settlement {
    my $self = shift;

    if ($self->tick_expiry) {
        return 1
            if ($self->exit_tick || ($self->date_pricing->epoch - $self->date_start->epoch > $self->_max_tick_expiry_duration->seconds));
    } else {
        return 1 if $self->get_time_to_settlement->seconds == 0;
    }

    return 0;
}

=head2 is_expired

Returns true if this contract is expired.

It is expired only if it passes the expiry time time and has valid exit tick.

=cut

sub is_expired { die "Calling ->is_expired on a ::Contract instance" }

=head2 is_legacy

True for obsolete contract types, see L<BOM::Product::Contract::Invalid>.

=cut

sub is_legacy { return 0 }

sub may_settle_automatically {
    my $self = shift;

    # For now, only trigger this condition when the bet is past expiry.
    return (not $self->get_time_to_settlement->seconds and not $self->is_valid_to_sell) ? 0 : 1;
}

sub apply_binary_limit {
    my $self = shift;

    my $apply_binary_limit = ($self->category_code eq 'lookback') ? 0 : 1;

    return $apply_binary_limit;
}

=head1 METHODS - Other

=cut

=head2 code

Alias for B</bet_type>.

TODO should be removed.

=cut

sub code { return shift->bet_type; }

=head2 debug_information

Pricing engine internal debug information hashref.

=cut

sub debug_information {
    my $self = shift;

    return $self->pricing_engine->can('debug_info') ? $self->pricing_engine->debug_info : {};
}

=head2 entry_spot

The entry spot price of the contract.

=cut

sub entry_spot {
    my $self = shift;

    my $entry_tick = $self->entry_tick or return undef;
    return $self->entry_tick->quote;
}

=head2 entry_spot_epoch

The entry spot epoch of the contract.

=cut

sub entry_spot_epoch {
    my $self = shift;

    my $entry_tick = $self->entry_tick or return undef;
    return $self->entry_tick->epoch;
}

=head2 expiry_type

The expiry type of a contract (daily, tick or intraday).

=cut

sub expiry_type {
    my $self = shift;

    return 'no_expiry' unless $self->category && $self->category->has_user_defined_expiry;
    return ($self->tick_expiry) ? 'tick' : ($self->expiry_daily) ? 'daily' : 'intraday';
}

=head2 expiry_daily

Returns true if this is not an intraday contract.

=cut

sub expiry_daily {
    my $self = shift;
    return $self->is_intraday ? 0 : 1;
}

=head2 date_settlement

When the contract was settled (can be C<undef>).


=cut

#TODO: We should remove the concept of date_settlement in our system once all the open contracts for indices close
sub date_settlement {
    my $self     = shift;
    my $end_date = $self->date_expiry;
    my $exchange = $self->underlying->exchange;

    my $date_settlement = $end_date;                 # Usually we settle when we expire.
    my $calendar        = $self->trading_calendar;
    if ($self->expiry_daily and $calendar->trades_on($exchange, $end_date)) {
        # We have a huge inefficiency at how we settle daily contracts that need to be fixed after we have
        # consistent feed. Currently, the OHLC of a trading day for a particular instrument is generated when we
        # receive the first tick on the next trading day. There's a database trigger set on 'tick_insert' function
        # in feed database to populate OHLC aggregation for different intervals (minutely, hourly & daily).
        #
        # This needs to change when we have consistent feed where we will have the OHLC of the trading day after market is closed
        # for the day. This isn't possible without consistent feed where we're still back-populating historical ticks.
        #
        # To solve MTM error where contracts are expired but could not be settled because of missing OHLC, we will
        # change the settlement time for daily contract to the next trading day open. E.g.:
        #
        # Hong Kong Index opens at 1:30GMT and closes a 8GMT on a normal trading day, If you buy a contract expiring on wednesday close,
        # your contract will only be settled on thursday when Hong Kong Index opens at 1:30GMT.
        # This affects daily contract on forex too on Fridays or when next day is a non-trading day.
        my $next_trading_day = $calendar->trade_date_after($exchange, $end_date);
        $date_settlement = $self->trading_calendar->opening_on($exchange, $next_trading_day);
    }

    return $date_settlement;
}

=head2 get_time_to_settlement

Like get_time_to_expiry, but for settlement time rather than expiry.

=cut

sub get_time_to_settlement {
    my ($self, $attributes) = @_;

    $attributes->{to} = $self->date_settlement;

    my $time          = $self->_date_pricing_milliseconds // $self->date_pricing->epoch;
    my $zero_duration = Time::Duration::Concise->new(
        interval => 0,
    );
    return ($time >= $self->date_settlement->epoch and $self->expiry_daily) ? $zero_duration : $self->_get_time_to_end($attributes);
}

=head2 longcode

Returns the longcode for this contract.

May throw an exception if an invalid expiry type is requested for this contract type.

=cut

sub longcode {
    my $self = shift;

    return shortcode_to_longcode($self->shortcode, $self->currency);
}

=head2 allowed_slippage

Ratio of slippage we allow for this contract, where 0.01 is 1%.

=cut

sub allowed_slippage {
    my $self = shift;

    # allowed_slippage for binary is in probability space, 0.01 = 1%
    return $self->base_commission * 0.5;
}

=head2 enqueue_settlement_epoch

Shall we push this contract into settlement queue.

Returns true if the contract has user defined expiry time.
Returns true if internal contract duration is set to be less than 1 year, else false.

=cut

sub enqueue_settlement_epoch {
    my $self = shift;

    return 1 if $self->category->has_user_defined_expiry;
    # Maximum contract duration is 1 year. For multipliers, there should be no expiry but as a workaround for swap charge on cryptocurrency,
    # we have imposed a shorter (7d, configurable from back-office) expiry for crypto multipliers.
    return 1 if $self->timeinyears->amount < 1;
    return 0;
}

# INTERNAL METHODS

#A TimeInterval which expresses the maximum time a tick trade may run, even if there are missing ticks in the middle.
sub _max_tick_expiry_duration {
    return Time::Duration::Concise->new(interval => '5m');
}

sub _check_is_intraday {
    my ($self, $date_start) = @_;
    my $date_expiry       = $self->date_expiry;
    my $contract_duration = $date_expiry->epoch - $date_start->epoch;

    return 0 if $contract_duration > 86400;

    # don't have to check closing time for volatility indices because it is using the same engine.
    # This is done for buy optimisation
    return 1 if ($self->market->name eq 'synthetic_index');

    my $trading_calendar = $self->trading_calendar;
    my $exchange         = $self->underlying->exchange;
    # for contract that start at the open of day and expire at the close of day (include early close) should be treated as daily contract
    my $closing = $trading_calendar->closing_on($exchange, $self->date_expiry);

    # An intraday if the market is close on expiry
    return 1 unless $closing;
    # daily trading seconds based on the market's trading hour
    my $daily_trading_seconds = $closing->epoch - $trading_calendar->opening_on($exchange, $date_expiry)->epoch;
    return 0 if $closing->is_same_as($self->date_expiry) and $contract_duration >= $daily_trading_seconds;

    return 1;
}

sub _add_error {
    my ($self, $err) = @_;
    $err->{set_by} = __PACKAGE__;
    $self->primary_validation_error(MooseX::Role::Validatable::Error->new(%$err));
    return;
}

#== BUILDERS =====================

# The pricing, greek and markup engines need the same set of arguments,
# so we provide this helper function which pulls all the revelant bits out of the object and
# returns a nice HashRef for them.
sub _build__pricing_args {
    my $self = shift;

    my $barriers_for_pricing = $self->barriers_for_pricing;
    my $payouttime_code      = ($self->payouttime eq 'hit') ? 0 : 1;
    my $args                 = {
        spot            => $self->pricing_spot,
        r_rate          => $self->r_rate,
        t               => $self->timeinyears->amount,
        barrier1        => $barriers_for_pricing->{barrier1},
        barrier2        => $barriers_for_pricing->{barrier2},
        q_rate          => $self->q_rate,
        iv              => $self->pricing_vol,
        discount_rate   => $self->discount_rate,
        mu              => $self->mu,
        payouttime_code => $payouttime_code,
    };

    if ($self->priced_with_intraday_model) {
        $args->{long_term_prediction} = $self->long_term_prediction;
    }

    return $args;
}

sub _build_is_intraday {
    my $self = shift;

    return $self->_check_is_intraday($self->effective_start);

}

sub _build_basis_tick {
    my $self = shift;

    my $waiting_for_entry_tick = $ERROR_MAPPING->{EntryTickMissing};
    my $missing_market_data    = $ERROR_MAPPING->{MissingMarketData};
    my ($basis_tick, $potential_error);

    # basis_tick is only set to entry_tick when the contract has started.
    if ($self->pricing_new) {
        $basis_tick      = $self->current_tick;
        $potential_error = $self->starts_as_forward_starting ? $waiting_for_entry_tick : $missing_market_data;
        warn "No basis tick for " . $self->underlying->symbol if ($potential_error eq $missing_market_data && !$basis_tick);
    } else {
        # basis_tick which is also the reference tick use in barrier calculation.
        # For relative barrier, the reference tick is always the entry tick.
        # For absolute barrier, the reference tick is the tick at start time for non-tick expiry contracts. For tick expiry, the reference tick is still the entry tick.
        $basis_tick =
            (       not $self->tick_expiry
                and $self->has_user_defined_barrier
                and $self->supplied_barrier
                and $self->supplied_barrier =~ /^(?:\d+.?\d{0,12})$/)
            ? $self->_tick_accessor->tick_at($self->date_start->epoch)
            : $self->entry_tick;
        $potential_error = $waiting_for_entry_tick;
    }

    # if there's no basis tick, don't die but catch the error.
    unless ($basis_tick) {
        $basis_tick = $self->_dummy_tick($self->date_pricing->epoch);
        $self->_add_error({
            message           => "Waiting for entry tick [symbol: " . $self->underlying->symbol . "]",
            message_to_client => [$potential_error],
            details           => {},
        });
    }

    return $basis_tick;
}

sub _build_current_spot {
    my $self = shift;

    my $spot = $self->current_tick or return undef;

    return $self->underlying->pipsized_value($spot->quote);
}

sub _build_current_tick {
    my $self = shift;

    return $self->_tick_accessor->spot_tick;
}

sub _build_opposite_contract_for_sale {
    my $self = shift;

    # Start by making a copy of the parameters we used to build this bet.
    my %opp_parameters = %{$self->build_parameters};
    # we still want to set for_sale for a forward_starting contracts
    $opp_parameters{for_sale} = 1;
    # delete traces of this contract were a forward starting contract before.
    delete $opp_parameters{starts_as_forward_starting};
    # duration could be set for an opposite contract from bad hash reference reused.
    delete $opp_parameters{duration};
    # Populate date expiry
    $opp_parameters{date_expiry} = $self->date_expiry;

    if (not $self->is_forward_starting) {
        if ($self->entry_tick) {
            foreach my $barrier ($self->two_barriers ? ('high_barrier', 'low_barrier') : ('barrier')) {
                if (defined $self->$barrier) {
                    $opp_parameters{$barrier} = $self->$barrier->as_absolute;
                    $opp_parameters{'supplied_' . $barrier} = $self->$barrier->as_absolute;
                }
            }
        }
        # We should be looking to move forward in time to a bet starting now.
        # We had issue during pricing when we try to price contract exactly at expiry time,
        # get_volatility was throwing error, since from and to are equal. Setting
        # date_start equal to date_start instead of date_pricing here for opposite contract
        # will solve this issue.
        $opp_parameters{date_start}  = ($self->date_pricing->epoch == $self->date_expiry->epoch) ? $self->date_start : $self->date_pricing;
        $opp_parameters{pricing_new} = 1;
        # This should be removed in our callput ATM and non ATM minimum allowed duration is identical.
        # Currently, 'sell at market' button will appear when current spot == barrier when the duration
        # of the contract is less than the minimum duration of non ATM contract.
    }

    # Always switch out the bet type for the other side.
    $opp_parameters{'bet_type'} = $self->other_side_code;
    # Don't set the shortcode, as it will change between these.
    delete $opp_parameters{'shortcode'};
    # Save a round trip.. copy market data
    foreach my $vol_param (qw(volsurface fordom forqqq domqqq)) {
        $opp_parameters{$vol_param} = $self->$vol_param;
    }

    $opp_parameters{'reset_time_in_years'} = $self->reset_time_in_years;

    my $opp_contract = $self->_produce_contract_ref->(\%opp_parameters);

    return $opp_contract;
}

sub _build_opposite_contract {
    my $self = shift;

    # Start by making a copy of the parameters we used to build this bet.
    my %opp_parameters = %{$self->build_parameters};
    # Opposite contract would have the same date_expir
    delete $opp_parameters{duration};
    # Always switch out the bet type for the other side.
    $opp_parameters{'bet_type'} = $self->other_side_code;
    # Don't set the shortcode, as it will change between these.
    delete $opp_parameters{'shortcode'};
    # Save a round trip.. copy market data
    # Populate date expiry
    $opp_parameters{date_expiry} = $self->date_expiry;
    foreach my $vol_param (qw(volsurface fordom forqqq domqqq)) {
        $opp_parameters{$vol_param} = $self->$vol_param;
    }

    # We have this concept in forward starting contract where a forward start contract is considered
    # pricing_new until it has started. So it kind of messed up here.
    $opp_parameters{current_tick} = $self->current_tick;
    my @to_override = qw(r_rate q_rate discount_rate pricing_vol pricing_spot mu);
    push @to_override, qw(long_term_prediction) if $self->priced_with_intraday_model;
    $opp_parameters{$_} = $self->$_ for @to_override;
    $opp_parameters{pricing_new} = 1;

    my $opp_contract = $self->_produce_contract_ref->(\%opp_parameters);

    return $opp_contract;
}

sub _build_entry_tick {
    my $self = shift;

    # entry tick if never defined if it is a newly priced contract.
    return if $self->pricing_new;
    my $entry_epoch = $self->date_start->epoch;
    return $self->_tick_accessor->tick_at($entry_epoch) if $self->starts_as_forward_starting;
    return $self->_tick_accessor->next_tick_after($entry_epoch);
}

sub _build_applicable_economic_events {
    my $self = shift;

    my $effective_start   = $self->effective_start;
    my $seconds_to_expiry = $self->get_time_to_expiry({from => $effective_start})->seconds;
    my $current_epoch     = $effective_start->epoch;

    # maximum lookback time should only be in one day.
    my $max_lookback_seconds = min($seconds_to_expiry, 86400);

    my $start = $current_epoch - $max_lookback_seconds;
    my $end   = $current_epoch + $seconds_to_expiry;

    my $events = Quant::Framework::EconomicEventCalendar->new({
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader($self->underlying->for_date),
        }
    )->get_latest_events_for_period({
            from => Date::Utility->new($start),
            to   => Date::Utility->new($end)
        },
        $self->underlying->for_date
    );
    $events = Volatility::EconomicEvents::categorize_events($self->underlying->system_symbol, $events);
    return $events;
}

sub _build_pricing_spot {
    my $self = shift;

    # always use current spot to price for sale or buy.
    my $initial_spot;
    if ($self->current_tick) {
        $initial_spot = $self->current_tick->quote;
    } else {
        # If we could not get the correct spot to price, we will take the latest available spot at pricing time.
        # This is to prevent undefined spot being passed to BlackScholes formula that causes the code to die!!
        my $dummy_tick = $self->_tick_accessor->tick_at($self->date_pricing->epoch, {allow_inconsistent => 1})
            // $self->_dummy_tick($self->date_pricing->epoch);
        $initial_spot = $dummy_tick->quote;
        $self->_add_error({
            message => 'Undefined spot '
                . "[date pricing: "
                . $self->date_pricing->datetime . "] "
                . "[symbol: "
                . $self->underlying->symbol . "]",
            message_to_client => [$ERROR_MAPPING->{CannotProcessContract}],
        });
    }

    return $initial_spot;
}

sub _build_apply_market_inefficient_limit {
    my $self = shift;

    return $self->market_is_inefficient && $self->priced_with_intraday_model;
}

# this needs to be a lazy build attribute because
# it determined the expiry condition of a contract.
has ticks_for_tick_expiry => (
    is         => 'ro',
    lazy_build => 1
);

sub _build_ticks_for_tick_expiry {
    my $self = shift;

    return $self->_tick_accessor->ticks_in_between_start_limit({
        start_time => $self->date_start->epoch + 1,
        limit      => $self->ticks_to_expiry,
    });
}

sub _build_exit_tick {
    my $self = shift;

    return if $self->pricing_new;

    my $underlying = $self->underlying;
    my $exit_tick;
    if ($self->tick_expiry) {
        my $tick_number       = $self->ticks_to_expiry;
        my @ticks_since_start = @{$self->ticks_for_tick_expiry};
        # We wait for the n-th tick to settle tick expiry contract.
        # But the maximum waiting period is 5 minutes.
        return undef unless @ticks_since_start == $tick_number;
        $exit_tick = $ticks_since_start[-1];

        return undef if $exit_tick->epoch > $self->date_pricing->epoch;
        $self->date_expiry(Date::Utility->new($exit_tick->epoch));
        $self->is_valid_exit_tick(1);
    } elsif ($self->is_after_expiry) {
        # For a daily contract or a contract expired at the close of trading, the valid exit tick should be the daily close else should be the tick at expiry date
        # IMPORTANT NOTE: $self->_tick_accessor does not support ->closing_tick_on();
        my $closing = $self->trading_calendar->closing_on($underlying->exchange, $self->date_expiry);

        my $valid_exit_tick_at_expiry = (
            $self->expiry_daily
                or ($closing and $self->date_expiry->is_same_as($closing))
        ) ? $underlying->closing_tick_on($self->date_expiry->date) : $self->_tick_accessor->tick_at($self->date_expiry->epoch);

        # There are few scenarios where we still do not have valid exit tick as follow. In those case, we will use last available tick at the expiry time to determine the pre-settlement value but will not be settle based on that tick
        # 1) For long term contract, after expiry yet pass the settlement time, waiting for daily ohlc to be updated
        # 2) For short term contract, waiting for next tick to arrive after expiry to determine the valid exit tick at expiry
        if (not $valid_exit_tick_at_expiry) {
            $exit_tick = $self->_tick_accessor->tick_at($self->date_expiry->epoch, {allow_inconsistent => 1});
        } else {
            $exit_tick = $valid_exit_tick_at_expiry;
            $self->is_valid_exit_tick(1);
        }
    }

    if ($self->entry_tick and $exit_tick) {
        my ($entry_tick_date, $exit_tick_date) = map { Date::Utility->new($_) } ($self->entry_tick->epoch, $exit_tick->epoch);
        if (    not $self->expiry_daily
            and $underlying->intradays_must_be_same_day
            and $self->trading_calendar->trading_days_between($underlying->exchange, $entry_tick_date, $exit_tick_date))
        {
            $self->_add_error({
                message => 'Exit tick date differs from entry tick date on intraday '
                    . "[symbol: "
                    . $underlying->symbol . "] "
                    . "[start: "
                    . $exit_tick_date->datetime . "] "
                    . "[expiry: "
                    . $entry_tick_date->datetime . "]",
                message_to_client => [$ERROR_MAPPING->{CrossMarketIntraday}],
                details           => {field => 'duration'},
            });
        }
    }

    return $exit_tick;
}

sub _build_date_expiry {

    my $self = shift;

    my $date_expiry;

    my $duration = $self->duration;
    if ($duration !~ /[0-9]+(t|m|d|s|h)/) {
        BOM::Product::Exception->throw(
            error_code => 'TradingDurationNotAllowed',
            details    => {field => 'duration'},
        );
    } else {
        # sanity check for duration. Date::Utility throws exception if you're trying
        # to create an object that's too ridiculous far in the future.

        my $expected_feed_frequency = $self->underlying->generation_interval->seconds;
        # defaults to 2-second if not specified
        $expected_feed_frequency = 2 if $expected_feed_frequency == 0;
        try {
            my ($duration_amount, $duration_unit) = $duration =~ /([0-9]+)(t|m|d|s|h)/;
            my $interval = $duration;
            $interval = $duration_amount * $expected_feed_frequency if $duration_unit eq 't';

            my $duration_in_seconds = $self->date_start->plus_time_interval($interval)->epoch - $self->date_start->epoch;
            die if ($self->category->has_user_defined_expiry) && ($duration_in_seconds > MAX_DURATION);
        } catch {
            BOM::Product::Exception->throw(
                error_code => 'TradingDurationNotAllowed',
                details    => {field => 'duration'});
        }
        if (my ($tick_count) = $duration =~ /^([0-9]+)t$/) {
            $date_expiry = $self->date_start->plus_time_interval($expected_feed_frequency * $self->tick_count);
        } else {
            my $underlying  = $self->underlying;
            my $start_epoch = $self->date_start;
            $date_expiry = $start_epoch->plus_time_interval($duration);

            if ($duration =~ /d$/) {
                # Daily bet expires at the end of day, so here you go
                if (my $closing = $self->trading_calendar->closing_on($underlying->exchange, $date_expiry)) {
                    $date_expiry = $closing;
                } else {
                    my $regular_day   = $self->trading_calendar->regular_trading_day_after($underlying->exchange, $date_expiry);
                    my $regular_close = $self->trading_calendar->closing_on($underlying->exchange, $regular_day);
                    $date_expiry = Date::Utility->new($date_expiry->date_yyyymmdd . ' ' . $regular_close->time_hhmmss);
                }
            }
        }
    }

    if ($self->category->has_user_defined_expiry) {
        my $start  = Date::Utility->new($self->date_start);
        my $expiry = Date::Utility->new($date_expiry);

        BOM::Product::Exception->throw(
            error_code => 'SameExpiryStartTime',
            details    => {field => defined($self->duration) ? 'duration' : 'date_expiry'},
        ) if $start->epoch == $expiry->epoch;
        BOM::Product::Exception->throw(
            error_code => 'PastExpiryTime',
            details    => {field => 'date_expiry'},
        ) if $expiry->is_before($start);
    }

    return $date_expiry;
}

# TO DO, landing_company to be moved out from Contract.
has landing_company => (
    is      => 'ro',
    default => undef,
);

sub _build_risk_profile {
    my $self = shift;

    # keep the ultra_short expiry type to risk profile.
    my $expiry_type = $self->expiry_type;
    if ($expiry_type eq 'intraday' and $self->remaining_time->seconds <= $self->app_config->quants->ultra_short_duration) {
        $expiry_type = 'ultra_short';
    }

    return BOM::Platform::RiskProfile->new(
        contract_category              => $self->category_code,
        expiry_type                    => $expiry_type,
        start_type                     => ($self->is_forward_starting ? 'forward' : 'spot'),
        currency                       => $self->currency,
        barrier_category               => $self->barrier_category,
        symbol                         => $self->underlying->symbol,
        market_name                    => $self->underlying->market->name,
        submarket_name                 => $self->underlying->submarket->name,
        underlying_risk_profile        => $self->underlying->risk_profile,
        underlying_risk_profile_setter => $self->underlying->risk_profile_setter,
        $self->landing_company ? (landing_company => $self->landing_company) : (),
    );
}

sub _build_app_config {
    return BOM::Config::Runtime->instance->app_config;
}

=head2 extra_info

get the extra pricing information of the contract.

->extra_info('string'); # returns a string of information separated by underscore
->extra_info('arrayref'); # returns an array reference of information

=cut

sub extra_info {
    my ($self, $as_type) = @_;

    die 'Supports \'string\' or \'arrayref\' type only' if (not($as_type eq 'string' or $as_type eq 'arrayref'));

    # We have these keys save in data_collection.quants_bet_variables.
    # Not going to change it for backward compatibility.
    my %mapper = (
        high_barrier_vol => 'iv',
        low_barrier_vol  => 'iv_2',
        pricing_vol      => 'iv',
    );
    my @extra = ([pricing_spot => $self->pricing_spot]);
    if ($self->priced_with_intraday_model) {
        push @extra, (map { [($mapper{$_} // $_) => $self->$_] } qw(pricing_vol long_term_prediction));
    } elsif ($self->pricing_vol_for_two_barriers) {
        push @extra, (map { [($mapper{$_} // $_) => $self->pricing_vol_for_two_barriers->{$_}] } qw(high_barrier_vol low_barrier_vol));
    } else {
        push @extra, [iv => $self->pricing_vol];
    }

    if (!$self->is_valid_to_buy && $self->primary_validation_error->message =~ /Quote too old/) {
        push @extra, [error => $self->primary_validation_error->message];
    }

    if ($as_type eq 'string') {
        my $string = join '_', map { $_->[1] } @extra;
        return $string;
    }

    return \@extra;
}

sub pricing_details {
    my ($self, $action) = @_;

    # non of these information actually valid for multiplier and accumulator, skipping it here
    return [] if ($self->category_code =~ /^(multiplier|accumulator)$/);

    # IV is the pricing vol (high barrier vol if it is double barrier contract), iv_2 is the low barrier vol.
    my $iv   = $self->is_after_expiry ? 0 : $self->pricing_vol;
    my $iv_2 = 0;

    if (not $self->is_after_expiry and $self->pricing_vol_for_two_barriers) {
        $iv   = $self->pricing_vol_for_two_barriers->{high_barrier_vol};
        $iv_2 = $self->pricing_vol_for_two_barriers->{low_barrier_vol};
    }

    # This way the order of the fields is well-defined.
    my @comment_fields = map { defined $_->[1] ? @$_ : (); } (
        [theo  => $self->theo_price],
        [iv    => $iv],
        [iv_2  => $iv_2],
        [win   => $self->payout],
        [div   => $self->q_rate],
        [int   => $self->r_rate],
        [delta => $self->delta],
        [gamma => $self->gamma],
        [vega  => $self->vega],
        [theta => $self->theta],
        [vanna => $self->vanna],
        [volga => $self->volga],
        [spot  => $self->current_spot],
        @{$self->extra_info('arrayref')},
    );

    my $tick;
    if ($action eq 'sell') {
        # current tick is lazy, even though the realtime cache might have changed during the course of the transaction.
        $tick = $self->current_tick;
    } elsif ($action eq 'autosell_expired_contract') {
        $tick = ($self->is_path_dependent and $self->hit_tick) ? $self->hit_tick : $self->exit_tick;
    }

    if ($tick) {
        push @comment_fields, (exit_spot       => $tick->quote);
        push @comment_fields, (exit_spot_epoch => $tick->epoch);
        if ($self->two_barriers) {
            push @comment_fields, (high_barrier => $self->high_barrier->as_absolute) if $self->high_barrier;
            push @comment_fields, (low_barrier  => $self->low_barrier->as_absolute)  if $self->low_barrier;
        } else {
            push @comment_fields, (barrier => $self->barrier->as_absolute) if $self->barrier;
        }
    }

    if ($self->entry_spot) {
        push @comment_fields, (entry_spot       => $self->entry_spot);
        push @comment_fields, (entry_spot_epoch => $self->entry_spot_epoch);
    }

    return \@comment_fields;
}

sub audit_details {
    my ($self, $sell_time) = @_;

    # If there's no entry tick, practically the contract hasn't started.
    return {} unless $self->entry_tick;

    my $start_epoch  = 0 + $self->date_start->epoch;
    my $expiry_epoch = 0 + $self->date_expiry->epoch;

    # rare case: no tics between date_start and date_expiry.
    # underlaying will return exit_tick preceding date_start
    # no audit because such contracts are settled by CS team
    return {} if $self->exit_tick and $start_epoch > $self->exit_tick->epoch;

    my $details;

    if ($self->tick_expiry) {
        $details = {
            all_ticks => $self->_get_tick_details({
                    requested_epoch => {
                        value => 0 + $start_epoch,
                        name  => [$GENERIC_MAPPING->{start_time}],
                    },
                    quote => {
                        value => 0 + $self->entry_tick->quote,
                        epoch => 0 + $self->entry_tick->epoch,
                        name  => [$GENERIC_MAPPING->{entry_spot_cap}],
                    }}
            ),
        };

        return $details;
    }

    $details = {
        contract_start => $self->_get_tick_details({
                requested_epoch => {
                    value => 0 + $start_epoch,
                    name  => [$GENERIC_MAPPING->{start_time}],
                },
                quote => {
                    value => 0 + $self->entry_tick->quote,
                    epoch => 0 + $self->entry_tick->epoch,
                    name  => [$GENERIC_MAPPING->{entry_spot_cap}],
                }}
        ),
    };

    # only contract_start audit details if contract is sold early.
    # path dependent could hit early, we will check if it is sold early or hit in the next condition.
    my $sell_date       = $sell_time ? Date::Utility->new($sell_time) : undef;
    my $manual_sellback = 0;
    $manual_sellback = $sell_date->is_before($self->date_expiry) if $sell_date;
    return $details if $self->is_sold && $manual_sellback && !$self->is_path_dependent;

    # no contract_end audit details if settlement conditions is not fulfilled.
    return $details unless $self->is_expired;
    return $details if $self->waiting_for_settlement_tick;
    my $closing = $self->trading_calendar->closing_on($self->underlying->exchange, $self->date_expiry);
    if ($self->is_path_dependent && $self->close_tick) {
        my $hit_tick = $self->close_tick;
        $details->{contract_end} = [{
                # "0 +" converts string into number. This was added to ensure some fields return the value as number instead of string
                epoch              => 0 + $hit_tick->epoch,
                tick               => $hit_tick->quote,
                tick_display_value => $self->underlying->pipsized_value($hit_tick->quote),
                name               => [$GENERIC_MAPPING->{exit_spot}],
                flag               => 'highlight_tick',
            }];
    } elsif ($self->expiry_daily
        or ($closing and $self->date_expiry->is_same_as($closing)))
    {
        my $closing_tick = $self->underlying->closing_tick_on($self->date_expiry->date);
        return $details unless $closing_tick;
        $details->{contract_end} = [{
                epoch              => 0 + $closing_tick->epoch,
                tick               => $closing_tick->quote,
                tick_display_value => $self->underlying->pipsized_value($closing_tick->quote),
                name               => [$GENERIC_MAPPING->{closing_spot}],
                flag               => 'highlight_tick',
            }];
    } else {
        $details->{contract_end} = $self->_get_tick_details({
                requested_epoch => {
                    value => 0 + $expiry_epoch,
                    name  => [$GENERIC_MAPPING->{end_time}],
                },
                quote => {
                    value => $self->exit_tick->quote,
                    epoch => 0 + $self->exit_tick->epoch,
                    name  => [$GENERIC_MAPPING->{exit_spot}],
                }});
    }
    return $details;
}

sub _get_tick_details {
    my ($self, $args) = @_;

    my $epoch       = 0 + $args->{requested_epoch}{value};
    my $epoch_name  = $args->{requested_epoch}{name};
    my $quote_epoch = 0 + $args->{quote}{epoch};
    my $quote_name  = $args->{quote}{name};

    my $limit = ($self->tick_expiry) ? 2 : 3;

    my @ticks_all;
    my @ticks_after;
    if ($self->tick_expiry) {
        my @tmp_ticks = @{
            $self->underlying->ticks_in_between_start_limit({
                    start_time => $epoch + 1,
                    limit      => $self->ticks_to_expiry + 1,
                }
            ) // []};
        push @ticks_all, @tmp_ticks;
    } else {
        my @tmp_ticks = @{
            $self->underlying->ticks_in_between_start_limit({
                    start_time => $epoch + 1,
                    limit      => 3,
                }
            ) // []};
        push @ticks_after, @tmp_ticks;
    }

    my @ticks_before = reverse @{
        $self->underlying->ticks_in_between_end_limit({
                end_time => 0 + $epoch,
                limit    => $limit,
            }
        ) // []};

    my @ticks = $self->tick_expiry ? (@ticks_before, @ticks_all) : (@ticks_before, @ticks_after);

    #Extra logic to highlight highlowticks
    my $selected_epoch;
    if ($self->category_code eq 'highlowticks') {
        $selected_epoch =
              ($self->code eq 'TICKHIGH' and $self->highest_tick) ? $self->highest_tick->epoch
            : ($self->code eq 'TICKLOW'  and $self->lowest_tick)  ? $self->lowest_tick->epoch
            :                                                       undef;
    }

    my @details;
    for (my $i = 0; $i <= $#ticks; $i++) {
        my $t         = $ticks[$i];
        my $t2        = $ticks[$i + 1];
        my $t_details = {
            epoch              => 0 + $t->epoch,
            tick               => $t->quote,
            tick_display_value => $self->underlying->pipsized_value($t->quote),
        };

        if ($t->epoch == $epoch && $t->epoch == $quote_epoch) {
            $t_details->{name} = [$GENERIC_MAPPING->{time_and_spot}, $epoch_name->[0], $quote_name->[0]];
            $t_details->{flag} = "highlight_tick";
        } elsif ($t->epoch == $epoch) {
            $t_details->{name} = $epoch_name;
            $t_details->{flag} = "highlight_time";
        } elsif ($t->epoch == $quote_epoch) {
            $t_details->{name} = $quote_name;
            $t_details->{flag} = "highlight_tick";
        }

        if ($self->tick_expiry && $self->is_path_dependent && $self->close_tick) {
            if ($t->epoch == $self->close_tick->epoch) {
                $t_details->{name} = [$GENERIC_MAPPING->{time_and_spot}, $GENERIC_MAPPING->{end_time}, $GENERIC_MAPPING->{exit_spot}];
                $t_details->{name} = [
                    $GENERIC_MAPPING->{time_and_spot},
                    [$GENERIC_MAPPING->{time_and_spot}, $GENERIC_MAPPING->{entry_spot_cap}, $GENERIC_MAPPING->{end_time}],
                    $GENERIC_MAPPING->{exit_spot}]
                    if ($self->entry_tick->epoch == $self->close_tick->epoch);
                $t_details->{flag} = "highlight_tick";
            }
        } elsif ($self->tick_expiry && $self->exit_tick && $t->epoch == $self->exit_tick->epoch) {
            $t_details->{name} = [$GENERIC_MAPPING->{exit_spot}];
            $t_details->{name} = [$GENERIC_MAPPING->{time_and_spot}, $GENERIC_MAPPING->{end_time}, $GENERIC_MAPPING->{exit_spot}]
                if ($self->date_expiry->epoch == $self->exit_tick->epoch);
            $t_details->{name} = [
                $GENERIC_MAPPING->{time_and_spot},
                [$GENERIC_MAPPING->{time_and_spot}, $GENERIC_MAPPING->{entry_spot_cap}, $GENERIC_MAPPING->{end_time}],
                $GENERIC_MAPPING->{exit_spot}]
                if ($self->entry_tick->epoch == $self->exit_tick->epoch);
            $t_details->{flag} = "highlight_tick";
        }

        #Extra logic to highlight highlowticks
        if ($self->category_code eq 'highlowticks') {
            if (defined $selected_epoch and $t->epoch == $selected_epoch) {
                my $tick_name = ($self->bet_type eq 'TICKHIGH') ? $GENERIC_MAPPING->{highest_spot} : $GENERIC_MAPPING->{lowest_spot};
                if ($t_details->{name}) {
                    $t_details->{name} = [$GENERIC_MAPPING->{time_and_spot}, $t_details->{name}, $tick_name];
                } else {
                    $t_details->{name} = [$tick_name];
                    $t_details->{flag} = "highlight_tick";
                }
            }
        }

        push @details, $t_details;

        # if there's no tick on start or end time.
        if ((!$t2 && $epoch > $t->epoch) || ($epoch > $t->epoch && $epoch < $t2->epoch)) {
            push @details,
                +{
                flag  => "highlight_time",
                name  => $epoch_name,
                epoch => 0 + $epoch
                };
        }
    }

    return \@details;
}

has tick_stream => (
    is         => 'ro',
    lazy_build => 1
);

sub _build_tick_stream {
    my $self = shift;

    if (not $self->tick_expiry) {

        return;
    }
    my @all_ticks = @{$self->ticks_for_tick_expiry};

    # for path dependent contract, there should be no more tick after close tick
    # because the contract technically has expired
    if ($self->is_path_dependent and $self->close_tick) {
        @all_ticks = grep { $_->epoch <= $self->close_tick->epoch } @all_ticks;
    }

    return [map { {epoch => $_->epoch, tick => $_->quote, tick_display_value => $self->underlying->pipsized_value($_->quote)} } @all_ticks];

}

=head2 metadata

Contract metadata.

=cut

sub metadata {
    my ($self, $action) = @_;

    $action //= 'buy';

    my $contract;
    if ($action eq 'buy') {
        $contract = $self;
    } else {
        $contract = $self->other_side_code ? $self->opposite_contract_for_sale : $self;
    }

    my $contract_duration = do {
        if ($contract->tick_expiry) {
            $contract->tick_count;
        } elsif (not $contract->expiry_daily) {
            $contract->remaining_time->seconds;
        } else {
            $contract->date_expiry->days_between($contract->date_start);
        }
    };

    return {
        contract_category => $contract->category->code,
        underlying_symbol => $contract->underlying->symbol,
        barrier_category  => $contract->barrier_category,
        expiry_type       => $contract->expiry_type,
        start_type        => ($contract->is_forward_starting ? 'forward' : 'spot'),
        contract_duration => $contract_duration,
        for_sale          => ($action ne 'buy'),
        contract_type     => $contract->code,
        market            => $contract->underlying->market->name,
    };
}

sub is_parameters_predefined {
    return 0;
}

my %count = (
    frxAUDJPY => 2,
    frxAUDUSD => 2,
    frxEURGBP => 2,
    frxUSDJPY => 3,
    frxEURUSD => 3,
    frxEURJPY => 3,
    frxGBPJPY => 3,
    frxUSDCAD => 3,
    frxGBPUSD => 3,
);

sub barrier_count_for_underlying {
    my $symbol = shift;
    return $count{$symbol} // 2;
}

sub barrier_tier {
    my $self = shift;

    # we do not need definition for two barrier contracts
    # because intraday forex engine only prices callput and touchnotouch
    return 'none' if $self->two_barriers;

    return 'ATM' if $self->is_atm_bet;

    my $barrier       = $self->barrier->as_absolute;
    my $current_spot  = $self->current_spot;
    my $diff          = $current_spot - $barrier;
    my $barrier_count = $self->barrier_count_for_underlying($self->underlying->symbol);

    my $pip_size_at = $self->underlying->symbol =~ /JPY/ ? 0.01 : 0.0001;
    # multi-barriers are set 5 pips apart from each other.
    my $maximum_difference = $pip_size_at * $barrier_count * 5;

    my $which_tier;
    # if difference between spot and barrier is more than the $maximum_difference (15 pips away) then we apply the max commission.
    $which_tier = 'max' if abs($diff) > $maximum_difference;
    unless (defined $which_tier) {
        for (1 .. $barrier_count) {
            my $tier_difference = $pip_size_at * $_ * 5;
            if (abs($diff) <= $tier_difference) {
                $which_tier = $_;
                last;
            }
        }
    }

    # something went wrong, charge the max commission for this barrier.
    $which_tier = 'max' unless defined $which_tier;

    my $highlow;
    if ($self->code =~ /CALL/) {
        $highlow = $diff > 0 ? 'ITM' : 'OTM';
    } elsif ($self->code =~ /PUT/) {
        $highlow = $diff < 0 ? 'ITM' : 'OTM';
    } elsif ($self->code =~ /(ONETOUCH|NOTOUCH)/) {
        $highlow = 'OTM';    # it is always out of the money for touch/notouch since contract expires when it is in the money
    } else {
        return 'none';       # unrecognize contract type for barrier_tier
    }

    return (join '_', ($highlow, $which_tier));
}

sub _build_priced_with_intraday_model {
    my $self = shift;

    # Intraday::Index is just a flat price + commission, so it is not considered as a model.
    return ($self->pricing_engine_name eq 'BOM::Product::Pricing::Engine::Intraday::Forex');
}

sub allowed_amount_type {
    return {
        stake  => 1,
        payout => 1,
    };
}

# Please do not extend code with $contract->is_settleable function. This function will be removed.
# To check if an open contract can be settled, use $self->is_expired and $self->is_valid_to_sell.
sub is_settleable {
    my $self = shift;

    return 1 if $self->is_sold;
    return ($self->is_expired and $self->is_valid_to_sell);
}

=head2 require_price_adjustment

does this contract require price adjustment

=cut

sub require_price_adjustment {
    return 1;
}

=head2 invalid_user_input

Validation error could be caused by a lot of reasons. We stored all rejected trades into
the database but some invalid contract will fail to provide information to be stored hence it causes
an exception to be thrown.

If this flag is set to true then it will not be stored in rejected table.

=cut

has invalid_user_input => (
    is      => 'rw',
    default => 0
);

=head2 payout_currency_type

payout currency can be fiat or cryptocurrency

=cut

has payout_currency_type => (
    is      => 'ro',
    default => undef,
);

my $socket;
my $pricing_service_config = {};

sub _socket {
    my $self = shift;

    if (not defined $socket and %$pricing_service_config) {
        $socket = IO::Socket::IP->new(
            Proto    => 'udp',
            PeerAddr => $pricing_service_config->{host},
            PeerPort => $pricing_service_config->{port},
        ) or die "can't connect to pricing service";

        $socket->blocking(0);
    }

    return $socket;
}

sub _publish {
    my ($self, $price_ref) = @_;

    # if no connection is established, then ignore.
    return unless $self->_socket;

    try {
        my $csv = join ',',
            ($self->shortcode, $self->currency, $self->date_pricing->epoch, ($price_ref->{ask_price} // 0), ($price_ref->{bid_price} // 0));
        $self->_socket->send($csv);
    } catch ($e) {
        warn "Failed to publish price for " . $self->shortcode . ': ' . $e;
    }

    return;
}

has _tick_accessor => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_tick_accessor',
);

sub _build_tick_accessor {
    my $self = shift;

    # historical pricing always use source from feed db
    return $self->underlying if $self->underlying->for_date;

    my $redis_accessor = BOM::Market::RedisTickAccessor->new(underlying => $self->underlying);
    # don't use $self->timeinyears or $self->remaining_time here because that measures from date_pricing to date_expiry
    my $original_contract_duration = $self->date_expiry->epoch - $self->date_start->epoch;
    return $redis_accessor
        if ($original_contract_duration < $redis_accessor->cache_retention_interval->seconds
        && $redis_accessor->has_cache($self->date_start->epoch - $original_contract_duration));

    # default back to feed db if we do not have cache
    return $self->underlying;
}

sub _dummy_tick {
    my ($self, $epoch) = @_;

    return Postgres::FeedDB::Spot::Tick->new(
        symbol => $self->underlying->symbol,
        quote  => $self->underlying->pip_size * 2,
        epoch  => $epoch,
        bid    => $self->underlying->pip_size,
        ask    => $self->underlying->pip_size,
    );
}

=head2 get_relative_shortcode

Maps the shortcode to a relative one, removing stake/payout, making start/end
relative to the current time, and absolute barriers to relative format.

    shortcode:
        PUT_FRXAUDCAD_8.52_1542808932_1542809700F_S0P_0
    get converted to:
        PUT_FRXAUDCAD_0_768F_S0P_0

=over 4

=item * C<shortcode> - Optional, the original shortcode to be converted

If missing, the current shortcode will be used.

=back

Returns the relative shortcode.

=cut

sub get_relative_shortcode {
    my ($self, $shortcode) = @_;

    $shortcode //= $self->shortcode;

    my $params = shortcode_to_parameters($shortcode);

    if (exists $params->{duration} and $params->{duration} =~ /t$/) {
        $params->{date_expiry} = uc $params->{duration};
    } else {
        $params->{date_expiry} -= $params->{date_start} || time;
        $params->{date_expiry} .= 'F' if $params->{fixed_expiry};
    }

    $params->{date_start} = $params->{starts_as_forward_starting} ? int($params->{date_start} - time) . 'F' : '0';

    $params->{high_barrier} //= $params->{barrier};
    $params->{low_barrier}  //= '0';

    $params->{$_} = $self->to_relative_barrier($params->{$_}, $params->{current_spot}, $params->{underlying}) for qw(high_barrier low_barrier);

    return uc join '_', map { $params->{$_} } qw(bet_type underlying date_start date_expiry high_barrier low_barrier);
}

=head2 to_relative_barrier

Converts a barrier to spot relative pip format. e.g. 'S1234P'

NOTE: Don't use this for barrier of C<DIGIT> contract types.

=over 4

=item * C<barrier> - The original barrier

=item * C<spot> - The current spot of the underlying

=item * C<symbol> - The underlying symbol used to calculate pip-sized value

=back

Returns the relative barrier.

=cut

sub to_relative_barrier {
    my (undef, $barrier, $spot, $symbol) = @_;

    return ($barrier // '') =~ s/\.//r if (!$barrier || $barrier =~ /^S/);

    my $underlying = _get_underlying_instance($symbol);

    $barrier -= ($spot // $underlying->spot()) if ($barrier !~ /^[+-]/);

    $barrier = $underlying->pipsized_value($barrier) =~ s/[+.]//gr;

    return "S${barrier}P";
}

sub is_valid_to_cancel {
    my $self = shift;

    $self->_add_error({
        message           => 'cannot cancel contract ' . $self->code,
        message_to_client => $ERROR_MAPPING->{CannotCancelContract},
    });

    return 0;
}

sub cancel_price {
    return 0;
}

sub is_non_zero_payout {
    my $self = shift;

    return $self->payout == 0 ? 0 : 1;
}

sub skip_streaming {
    my $self = shift;

    # Do not skip if contract does not have defined expiry. Currently, multipliers and accumulators do not have pre-defined expiry.
    return 0 unless $self->category->has_user_defined_expiry;
    # Only skip random_index and random_daily for now. This list might need updating if we introduce more synthetic indices
    # to binary options.
    return 0 if $self->underlying->submarket->name ne 'random_index' and $self->underlying->submarket->name ne 'random_daily';
    # Digits, asian, highlowticks & reset options will not require price streaming
    # because of static price.
    return 1 if $self->category_code =~ /^(?:digits|asian|highlowticks|reset)$/;
    # Skip callput and callputequal intraday and tick_expiry ATM contracts
    return 1 if (not $self->expiry_daily and ($self->category_code eq 'callput' or $self->category_code eq 'callputequal') and $self->is_atm_bet);

    return 0;
}

my $underlyings;

sub _get_underlying_instance {
    my ($symbol) = @_;

    $underlyings->{$symbol} //= create_underlying($symbol);

    return $underlyings->{$symbol};
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

=head1 TEST

    # run all test scripts
    make test
    # run one script
    prove t/BOM/001_structure.t
    # run one script with perl
    perl -MBOM::Test t/BOM/001_structure.t

=cut
