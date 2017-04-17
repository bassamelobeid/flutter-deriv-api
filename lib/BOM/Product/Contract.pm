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

require UNIVERSAL::require;

use MooseX::Role::Validatable::Error;
use Time::HiRes qw(time);
use List::Util qw(min max first);
use Scalar::Util qw(looks_like_number);
use Math::Util::CalculatedValue::Validatable;
use Date::Utility;
use Format::Util::Numbers qw(to_monetary_number_format roundnear);
use Time::Duration::Concise;

use Quant::Framework::VolSurface::Utils;
use Quant::Framework::EconomicEventCalendar;
use Postgres::FeedDB::Spot::Tick;
use Price::Calculator;
use LandingCompany::Offerings qw(get_contract_specifics);

use BOM::Platform::Chronicle;
use BOM::Platform::Context qw(localize);
use BOM::MarketData::Types;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Product::Contract::Category;
use BOM::Platform::RiskProfile;
use BOM::Product::Types;
use BOM::Product::ContractValidator;
use BOM::Product::ContractPricer;

# require Pricing:: modules to avoid circular dependency problems.
UNITCHECK {
    use BOM::Product::Pricing::Engine::Intraday::Forex;
    use BOM::Product::Pricing::Engine::Intraday::Index;
    use BOM::Product::Pricing::Engine::VannaVolga::Calibrated;
    use BOM::Product::Pricing::Greeks::BlackScholes;
}

my @date_attribute = (
    isa        => 'date_object',
    lazy_build => 1,
    coerce     => 1,
);

=head1 ATTRIBUTES - Construction

These are the parameters we expect to be passed when constructing a new contract.
These would be passed to L<BOM::Product::ContractFactory/produce_contract>.

=cut

=head2 currency

The currency in which this contract is bought/sold, e.g. C<USD>.

=cut

has currency => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

=head2 payout

Payout amount value, see L</currency>.

=cut

has payout => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

=head2 shortcode

(optional) This can be provided when creating a contract from a shortcode. If not, it will
be populated from the contract parameters.

=cut

has shortcode => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

=head2 underlying

The underlying asset, as a L<Finance::Asset::Underlying> instance.

=cut

has underlying => (
    is      => 'ro',
    isa     => 'underlying_object',
    coerce  => 1,
    handles => [qw(market pip_size)],
);

=head1 ATTRIBUTES - Date-related

=cut

=head2 date_expiry

When the contract expires.

=cut

has date_expiry => (
    is => 'rw',
    @date_attribute,
);

=head2 date_pricing

The date at which we're pricing the contract. Provide C< undef > to indicate "now".

=cut

has date_pricing => (
    is => 'ro',
    @date_attribute,
);

=head2 date_start

For American contracts, defines when the contract starts.

For Europeans, this is used to determine the barrier when the requested barrier is relative.

=cut

has date_start => (
    is => 'ro',
    @date_attribute,
);

=head2 duration

The requested contract duration, specified as a string indicating value with units.
The unit is provided as a single character suffix:

=over 4

=item * t - ticks

=item * s - seconds

=item * m - minutes

=item * h - hours

=item * d - days

=back

Examples would be C< 5t > for 5 ticks, C< 3h > for 3 hours.

=cut

has duration => (is => 'ro');

=head1 ATTRIBUTES - Tick-expiry contracts

These are only valid for tick contracts.

=cut

=head2 tick_expiry

A boolean that indicates if a contract expires after a pre-specified number of ticks.

=cut

has tick_expiry => (
    is      => 'ro',
    default => 0,
);

=head2 prediction

Prediction (for tick trades) is what client predicted would happen.

=cut

has prediction => (
    is  => 'ro',
    isa => 'Maybe[Num]',
);

=head2 tick_count

Number of ticks in this trade.

=cut

has tick_count => (
    is  => 'ro',
    isa => 'Maybe[Num]',
);

=head1 ATTRIBUTES - Other

=cut

=head2 starts_as_forward_starting

This attribute tells us if this contract was initially bought as a forward starting contract.
This should not be mistaken for is_forwarding_start attribute as that could change over time.

=cut

has starts_as_forward_starting => (
    is      => 'ro',
    default => 0,
);

#expiry_daily - Does this bet expire at close of the exchange?
has [qw(
        is_intraday
        is_forward_starting
        )
    ] => (
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

has [qw(
        current_spot)
    ] => (
    is         => 'rw',
    isa        => 'Maybe[PositiveNum]',
    lazy_build => 1,
    );

=head2 for_sale

Was this bet built using BOM-generated parameters, as opposed to user-supplied parameters?

Be sure, as this allows us to relax some checks. Don't relax too much, as this still came from a
user at some point.. and they are wily.

This will contain the shortcode of the original bet, if we built it from one.

=cut

has for_sale => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
);

has build_parameters => (
    is  => 'ro',
    isa => 'HashRef',
    # Required until it goes away entirely.
    required => 1,
);

#fixed_expiry - A Boolean to determine if this bet has fixed or flexible expiries.

has fixed_expiry => (
    is      => 'ro',
    default => 0,
);

has calendar => (
    is      => 'ro',
    isa     => 'Quant::Framework::TradingCalendar',
    lazy    => 1,
    default => sub { return shift->underlying->calendar; },
);

has [qw(opposite_contract opposite_contract_for_sale)] => (
    is         => 'ro',
    isa        => 'BOM::Product::Contract',
    lazy_build => 1
);

has remaining_time => (
    is         => 'ro',
    isa        => 'Time::Duration::Concise',
    lazy_build => 1,
);

has corporate_actions => (
    is         => 'ro',
    lazy_build => 1,
);

has tentative_events => (
    is         => 'ro',
    lazy_build => 1,
);

# We adopt "near-far" methodology to price in dividends by adjusting spot and strike.
# This returns a hash reference with spot and barrrier adjustment for the bet period.
has dividend_adjustment => (
    is         => 'ro',
    lazy_build => 1,
);

has is_sold => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0
);

has risk_profile => (
    is         => 'ro',
    lazy_build => 1,
    init_arg   => undef,
);

# pricing_spot - The spot used in pricing.  It may have been adjusted for corporate actions.
has pricing_spot => (
    is         => 'ro',
    lazy_build => 1,
);

has [qw(barrier_category)] => (
    is         => 'ro',
    lazy_build => 1,
);

has exit_tick => (
    is         => 'ro',
    lazy_build => 1,
);

has primary_validation_error => (
    is       => 'rw',
    init_arg => undef,
);

has 'staking_limits' => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

has apply_market_inefficient_limit => (
    is         => 'ro',
    lazy_build => 1,
);

#A TimeInterval which expresses the maximum time a tick trade may run, even if there are missing ticks in the middle.
has _max_tick_expiry_duration => (
    is      => 'ro',
    isa     => 'time_interval',
    default => '5m',
    coerce  => 1,
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

# This is needed to determine if a contract is newly priced
# or it is repriced from an existing contract.
# Milliseconds matters since UI is reacting much faster now.
has _date_pricing_milliseconds => (
    is => 'rw',
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

=head1 ATTRIBUTES - From contract_types.yml

=head2 id

=head2 pricing_code

=head2 display_name

=head2 sentiment

=head2 other_side_code

=head2 payout_type

=head2 payouttime

=cut

has [qw(id pricing_code display_name sentiment other_side_code payout_type payouttime)] => (
    is      => 'ro',
    default => undef,
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
        return 1
            if ($self->exit_tick || ($self->date_pricing->epoch - $self->date_start->epoch > $self->_max_tick_expiry_duration->seconds));
    } else {

        return 1 if $self->get_time_to_expiry->seconds == 0;
    }
    return 0;
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

=head2 is_atm_bet

Is this contract meant to be ATM or non ATM at start?
The status will not change throughout the lifetime of the contract due to differences in offerings for ATM and non ATM contracts.

=cut

sub is_atm_bet {
    my $self = shift;

    return 0 if $self->two_barriers;
    # if not defined, it is non ATM
    return 0 if not defined $self->supplied_barrier;
    return 0 if $self->supplied_barrier ne 'S0P';
    return 1;
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

=head2 is_settleable

Returns true if the contract is settleable.

To be able to settle, it need pass the settlement time and has valid exit tick

=cut

sub is_settleable { die "Calling ->is_settleable on a ::Contract instance" }

sub may_settle_automatically {
    my $self = shift;

    # For now, only trigger this condition when the bet is past expiry.
    return (not $self->get_time_to_settlement->seconds and not $self->is_valid_to_sell) ? 0 : 1;
}

=head1 METHODS - Proxied to L<BOM::Product::Contract::Category>

Our C<category> attribute provides several helper methods:

=cut

has category => (
    is      => 'ro',
    isa     => 'bom_contract_category',
    coerce  => 1,
    handles => [qw(supported_expiries is_path_dependent allow_forward_starting two_barriers barrier_at_start)],
);

=head2 supported_expiries

Which expiry durations we allow. Values can be:

=over 4

=item * intraday

=item * daily

=item * tick

=back

=cut

=head2 supported_start_types

(removed)

=cut

=head2 is_path_dependent

True if this is a path-dependent contract.

=cut

=head2 allow_forward_starting

True if we allow forward starting for this contract type.

=cut

=head2 two_barriers

True if the contract has two barriers.

=cut

=head2 barrier_at_start

The starting barrier value.

=cut

=head2 category_code

The code for this category.

=cut

sub category_code {
    my $self = shift;
    return $self->category->code;
}

=head1 METHODS - Time-related

=cut

=head2 timeinyears

Contract duration in years.

=head2 timeindays

Contract duration in days.

=cut

has [qw(
        timeinyears
        timeindays
        )
    ] => (
    is         => 'ro',
    init_arg   => undef,
    isa        => 'Math::Util::CalculatedValue::Validatable',
    lazy_build => 1,
    );

sub _build_timeinyears {
    my $self = shift;

    my $tiy = Math::Util::CalculatedValue::Validatable->new({
        name        => 'time_in_years',
        description => 'Bet duration in years',
        set_by      => 'BOM::Product::Contract',
        base_amount => 0,
        minimum     => 0.000000001,
    });

    my $days_per_year = Math::Util::CalculatedValue::Validatable->new({
        name        => 'days_per_year',
        description => 'We use a 365 day year.',
        set_by      => 'BOM::Product::Contract',
        base_amount => 365,
    });

    $tiy->include_adjustment('add',    $self->timeindays);
    $tiy->include_adjustment('divide', $days_per_year);

    return $tiy;
}

sub _build_timeindays {
    my $self = shift;

    my $atid = $self->get_time_to_expiry({
            from => $self->effective_start,
        })->days;

    my $tid = Math::Util::CalculatedValue::Validatable->new({
        name        => 'time_in_days',
        description => 'Duration of this bet in days',
        set_by      => 'BOM::Product::Contract',
        minimum     => 0.000001,
        maximum     => 730,
        base_amount => $atid,
    });

    return $tid;
}

=head1 METHODS - Other

=cut

=head2 debug_information

Pricing engine internal debug information hashref.

=cut

sub debug_information {
    my $self = shift;

    return $self->pricing_engine->can('debug_info') ? $self->pricing_engine->debug_info : {};
}

=head2 ticks_to_expiry

Number of ticks until expiry of this contract. Defaults to one more than tick_count,
TODO JB - this is overridden in the digit/Asian contracts, any idea why?

=cut

sub ticks_to_expiry {
    return shift->tick_count + 1;
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

=head2 effective_start

=over 4

=item * For backpricing, this is L</date_start>.

=item * For a forward-starting contract, this is L</date_start>.

=item * For all other states - i.e. active, non-expired contracts - this is L</date_pricing>.

=back

=cut

sub effective_start {
    my $self = shift;

    return
          ($self->date_pricing->is_after($self->date_expiry)) ? $self->date_start
        : ($self->date_pricing->is_after($self->date_start))  ? $self->date_pricing
        :                                                       $self->date_start;
}

=head2 expiry_type

The expiry type of a contract (daily, tick or intraday).

=cut

sub expiry_type {
    my $self = shift;

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

sub date_settlement {
    my $self       = shift;
    my $end_date   = $self->date_expiry;
    my $underlying = $self->underlying;

    my $date_settlement = $end_date;    # Usually we settle when we expire.
    if ($self->expiry_daily and $self->calendar->trades_on($end_date)) {
        $date_settlement = $self->calendar->settlement_on($end_date);
    }

    return $date_settlement;
}

=head2 get_time_to_expiry

Returns a TimeInterval to expiry of the bet. For a forward start bet, it will NOT return the bet lifetime, but the time till the bet expires.

If you want to get the contract life time, use:

    $contract->get_time_to_expiry({from => $contract->date_start})

=cut

sub get_time_to_expiry {
    my ($self, $attributes) = @_;

    $attributes->{'to'} = $self->date_expiry;

    return $self->_get_time_to_end($attributes);
}

=head2 get_time_to_settlement

Like get_time_to_expiry, but for settlement time rather than expiry.

=cut

sub get_time_to_settlement {
    my ($self, $attributes) = @_;

    $attributes->{to} = $self->date_settlement;

    my $time = $self->_date_pricing_milliseconds // $self->date_pricing->epoch;
    my $zero_duration = Time::Duration::Concise->new(
        interval => 0,
    );
    return ($time >= $self->date_settlement->epoch and $self->expiry_daily) ? $zero_duration : $self->_get_time_to_end($attributes);
}

=head2 longcode

Returns the (localized) longcode for this contract.

May throw an exception if an invalid expiry type is requested for this contract type.

=cut

sub longcode {
    my $self = shift;

    # When we are building the longcode, we should always take the date_start to date_expiry as duration.
    # Don't use $self->expiry_type because that's use to price a contract at effective_start time.
    my $forward_starting_contract = ($self->starts_as_forward_starting or $self->is_forward_starting);
    my $expiry_type = $self->tick_expiry ? 'tick' : $self->_check_is_intraday($self->date_start) == 0 ? 'daily' : 'intraday';
    $expiry_type .= '_fixed_expiry' if $expiry_type eq 'intraday' and not $forward_starting_contract and $self->fixed_expiry;
    my $localizable_description = $self->localizable_description->{$expiry_type} // die "Unknown expiry_type $expiry_type for " . ref($self);

    my ($when_end, $when_start);
    if ($expiry_type eq 'intraday_fixed_expiry') {
        $when_end   = $self->date_expiry->datetime . ' GMT';
        $when_start = '';
    } elsif ($expiry_type eq 'intraday') {
        $when_end = $self->get_time_to_expiry({from => $self->date_start})->as_string;
        $when_start = ($forward_starting_contract) ? $self->date_start->db_timestamp . ' GMT' : localize('contract start time');
    } elsif ($expiry_type eq 'daily') {
        my $close = $self->underlying->calendar->closing_on($self->date_expiry);
        if ($close and $close->epoch != $self->date_expiry->epoch) {
            $when_end = $self->date_expiry->datetime . ' GMT';
        } else {
            $when_end = localize('close on [_1]', $self->date_expiry->date);
        }
        $when_start = '';
    } elsif ($expiry_type eq 'tick') {
        $when_end   = $self->tick_count;
        $when_start = localize('first tick');
    }
    my $payout = to_monetary_number_format($self->payout);
    my @barriers = ($self->two_barriers) ? ($self->high_barrier, $self->low_barrier) : ($self->barrier);
    @barriers = map { $_->display_text if $_ } @barriers;

    return localize($localizable_description,
        ($self->currency, $payout, localize($self->underlying->display_name), $when_start, $when_end, @barriers));
}

=head2 allowed_slippage

Ratio of slippage we allow for this contract, where 0.01 is 1%.

=cut

sub allowed_slippage {
    my $self = shift;

    # our commission for volatility indices is 1.5% so we can let it slipped more than that.
    return 0.01 if $self->market->name eq 'volidx';
    return 0.0175;
}

# INTERNAL METHODS

sub _offering_specifics {
    my $self = shift;

    return get_contract_specifics(
        BOM::Platform::Runtime->instance->get_offerings_config,
        {
            underlying_symbol => $self->underlying->symbol,
            barrier_category  => $self->barrier_category,
            expiry_type       => $self->expiry_type,
            start_type        => ($self->is_forward_starting ? 'forward' : 'spot'),
            contract_category => $self->category->code,
            ($self->can('landing_company') ? (landing_company => $self->landing_company) : ()),    # this is done for japan
        });
}

sub _check_is_intraday {
    my ($self, $date_start) = @_;
    my $date_expiry       = $self->date_expiry;
    my $contract_duration = $date_expiry->epoch - $date_start->epoch;

    return 0 if $contract_duration > 86400;

    # for contract that start at the open of day and expire at the close of day (include early close) should be treated as daily contract
    my $closing = $self->calendar->closing_on($self->date_expiry);

    # An intraday if the market is close on expiry
    return 1 unless $closing;
    my $calendar = $self->calendar;
    # daily trading seconds based on the market's trading hour
    my $daily_trading_seconds = $calendar->closing_on($date_expiry)->epoch - $calendar->opening_on($date_expiry)->epoch;
    return 0 if $closing->is_same_as($self->date_expiry) and $contract_duration >= $daily_trading_seconds;

    return 1;
}

# Send in the correct 'to'
sub _get_time_to_end {
    my ($self, $attributes) = @_;

    my $end_point = $attributes->{to};
    my $from = ($attributes and $attributes->{from}) ? $attributes->{from} : $self->date_pricing;

    # Don't worry about how long past expiry
    # Let it die if they gave us nonsense.

    return Time::Duration::Concise->new(
        interval => max(0, $end_point->epoch - $from->epoch),
    );
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

    my $start_date           = $self->date_pricing;
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
        #order is important: long_term_prediction is being set in news_adjusted_pricing_vol calucalation
        $args->{iv_with_news}         = $self->news_adjusted_pricing_vol;
        $args->{long_term_prediction} = $self->intradayfx_volsurface->long_term_prediction;
    }

    return $args;
}

sub _build_date_pricing {
    my $self = shift;
    my $time = Time::HiRes::time();
    $self->_date_pricing_milliseconds($time);
    my $now = Date::Utility->new($time);
    return ($self->has_pricing_new and $self->pricing_new)
        ? $self->date_start
        : $now;
}

sub _build_is_intraday {
    my $self = shift;

    return $self->_check_is_intraday($self->effective_start);

}

sub _build_is_forward_starting {
    my $self = shift;

    return ($self->allow_forward_starting and $self->date_pricing->is_before($self->date_start)) ? 1 : 0;
}

sub _build_basis_tick {
    my $self = shift;

    my $waiting_for_entry_tick = localize('Waiting for entry tick.');
    my $missing_market_data    = localize('Trading on this market is suspended due to missing market data.');
    my ($basis_tick, $potential_error);

    # basis_tick is only set to entry_tick when the contract has started.
    if ($self->pricing_new) {
        $basis_tick = $self->current_tick;
        $potential_error = $self->starts_as_forward_starting ? $waiting_for_entry_tick : $missing_market_data;
        warn "No basis tick for " . $self->underlying->symbol if ($potential_error eq $missing_market_data && !$basis_tick);
    } else {
        $basis_tick      = $self->entry_tick;
        $potential_error = $waiting_for_entry_tick;
    }

    # if there's no basis tick, don't die but catch the error.
    unless ($basis_tick) {
        $basis_tick = Postgres::FeedDB::Spot::Tick->new({
            # slope pricer will die with illegal division by zero error when we get the slope
            quote  => $self->underlying->pip_size * 2,
            epoch  => time,
            symbol => $self->underlying->symbol,
        });
        $self->_add_error({
            message           => "Waiting for entry tick [symbol: " . $self->underlying->symbol . "]",
            message_to_client => $potential_error,
        });
    }

    return $basis_tick;
}

sub _build_remaining_time {
    my $self = shift;

    my $when = ($self->date_pricing->is_after($self->date_start)) ? $self->date_pricing : $self->date_start;

    return $self->get_time_to_expiry({
        from => $when,
    });
}

sub _build_current_spot {
    my $self = shift;

    my $spot = $self->current_tick or return undef;

    return $self->underlying->pipsized_value($spot->quote);
}

sub _build_current_tick {
    my $self = shift;

    return $self->underlying->spot_tick;
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
        $opp_parameters{date_start}  = $self->date_pricing;
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

    # we still want to set for_sale for a forward_starting contracts
    $opp_parameters{for_sale} = 1;
    # delete traces of this contract were a forward starting contract before.
    delete $opp_parameters{starts_as_forward_starting};
    # duration could be set for an opposite contract from bad hash reference reused.
    delete $opp_parameters{duration};

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
        $opp_parameters{date_start}  = $self->date_pricing;
        $opp_parameters{pricing_new} = 1;
    }

    my $opp_contract = $self->_produce_contract_ref->(\%opp_parameters);

    if (my $role = $opp_parameters{role}) {
        $role->require;
        $role->meta->apply($opp_contract);
    }

    return $opp_contract;
}

sub _build_opposite_contract {
    my $self = shift;

    # Start by making a copy of the parameters we used to build this bet.
    my %opp_parameters = %{$self->build_parameters};
    # Always switch out the bet type for the other side.
    $opp_parameters{'bet_type'} = $self->other_side_code;
    # Don't set the shortcode, as it will change between these.
    delete $opp_parameters{'shortcode'};
    # Save a round trip.. copy market data
    foreach my $vol_param (qw(volsurface fordom forqqq domqqq)) {
        $opp_parameters{$vol_param} = $self->$vol_param;
    }

    # We have this concept in forward starting contract where a forward start contract is considered
    # pricing_new until it has started. So it kind of messed up here.
    $opp_parameters{current_tick} = $self->current_tick;
    my @to_override = qw(r_rate q_rate discount_rate pricing_vol pricing_spot mu);
    push @to_override, qw(volatility_scaling_factor long_term_prediction) if $self->priced_with_intraday_model;
    $opp_parameters{$_} = $self->$_ for @to_override;
    $opp_parameters{pricing_new} = 1;

    my $opp_contract = $self->_produce_contract_ref->(\%opp_parameters);

    if (my $role = $opp_parameters{role}) {
        $role->require;
        $role->meta->apply($opp_contract);
    }

    return $opp_contract;
}

sub _build_corporate_actions {
    my $self = shift;

    my @actions;
    my $underlying = $self->underlying;

    if ($underlying->market->affected_by_corporate_actions) {
        my $first_day_close = $underlying->calendar->closing_on($self->date_start);
        if ($first_day_close and not $self->date_expiry->is_before($first_day_close)) {
            @actions = $self->underlying->get_applicable_corporate_actions_for_period({
                start => $self->date_start,
                end   => $self->date_pricing,
            });
        }
    }

    return \@actions;
}

sub _build_dividend_adjustment {
    my $self = shift;

    my $dividend_adjustment = $self->underlying->dividend_adjustments_for_period({
        start => $self->date_pricing,
        end   => $self->date_expiry,
    });

    my @corporate_actions = $self->underlying->get_applicable_corporate_actions_for_period({
        start => $self->date_pricing->truncate_to_day,
        end   => Date::Utility->new,
    });

    my $dividend_recorded_date = $dividend_adjustment->{recorded_date};

    if (scalar @corporate_actions
        and (my $action = first { Date::Utility->new($_->{effective_date})->is_after($dividend_recorded_date) } @corporate_actions))
    {

        warn "Missing dividend data: corp actions are " . join(',', @corporate_actions) . " and found date for action " . $action;
        $self->_add_error({
            message => 'Dividend is not updated  after corporate action'
                . "[dividend recorded date : "
                . $dividend_recorded_date->datetime . "] "
                . "[symbol: "
                . $self->underlying->symbol . "]",
            message_to_client => localize('Trading on this market is suspended due to missing market (dividend) data.'),
        });

    }

    return $dividend_adjustment;

}

sub _build_payout {
    my ($self) = @_;

    $self->_set_price_calculator_params('payout');
    return $self->price_calculator->payout;
}

sub _build_shortcode {
    my $self = shift;

    my $shortcode_date_start = (
               $self->is_forward_starting
            or $self->starts_as_forward_starting
    ) ? $self->date_start->epoch . 'F' : $self->date_start->epoch;
    my $shortcode_date_expiry =
          ($self->tick_expiry)  ? $self->tick_count . 'T'
        : ($self->fixed_expiry) ? $self->date_expiry->epoch . 'F'
        :                         $self->date_expiry->epoch;

    my @shortcode_elements = ($self->code, $self->underlying->symbol, $self->payout, $shortcode_date_start, $shortcode_date_expiry);

    if ($self->two_barriers) {
        push @shortcode_elements, ($self->high_barrier->for_shortcode, $self->low_barrier->for_shortcode);
    } elsif ($self->barrier and $self->barrier_at_start) {
        # Having a hardcoded 0 for single barrier is dumb.
        # We should get rid of this legacy
        push @shortcode_elements, ($self->barrier->for_shortcode, 0);
    }

    return uc join '_', @shortcode_elements;
}

sub _build_entry_tick {
    my $self = shift;

    # entry tick if never defined if it is a newly priced contract.
    return if $self->pricing_new;
    my $entry_epoch = $self->date_start->epoch;
    return $self->underlying->tick_at($entry_epoch) if $self->starts_as_forward_starting;
    return $self->underlying->next_tick_after($entry_epoch);
}

sub _build_date_start {
    return Date::Utility->new;
}

sub _build_applicable_economic_events {
    my $self = shift;

    my $effective_start   = $self->effective_start;
    my $seconds_to_expiry = $self->get_time_to_expiry({from => $effective_start})->seconds;
    my $current_epoch     = $effective_start->epoch;
    # Go back and forward an hour to get all the tentative events.
    my $start = $current_epoch - $seconds_to_expiry - 3600;
    my $end   = $current_epoch + $seconds_to_expiry + 3600;

    return Quant::Framework::EconomicEventCalendar->new({
            chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader($self->underlying->for_date),
        }
        )->get_latest_events_for_period({
            from => Date::Utility->new($start),
            to   => Date::Utility->new($end)});
}

sub _build_tentative_events {
    my $self = shift;

    my %affected_currency = (
        $self->underlying->asset_symbol           => 1,
        $self->underlying->quoted_currency_symbol => 1,
    );
    return [grep { $_->{is_tentative} and $affected_currency{$_->{symbol}} } @{$self->_applicable_economic_events}];
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
        $initial_spot = $self->underlying->tick_at($self->date_pricing->epoch, {allow_inconsistent => 1});
        $initial_spot //= $self->underlying->pip_size * 2;
        $self->_add_error({
            message => 'Undefined spot '
                . "[date pricing: "
                . $self->date_pricing->datetime . "] "
                . "[symbol: "
                . $self->underlying->symbol . "]",
            message_to_client => localize('We could not process this contract at this time.'),
        });
    }

    if ($self->underlying->market->prefer_discrete_dividend) {
        $initial_spot += $self->dividend_adjustment->{spot};
    }

    return $initial_spot;
}

sub _build_barrier_category {
    my $self = shift;

    my $barrier_category;
    if ($self->category->code eq 'callput') {
        $barrier_category = ($self->is_atm_bet) ? 'euro_atm' : 'euro_non_atm';
    } else {
        $barrier_category = $LandingCompany::Offerings::BARRIER_CATEGORIES->{$self->category->code}->[0];
    }

    return $barrier_category;
}

sub _build_apply_market_inefficient_limit {
    my $self = shift;

    return $self->market_is_inefficient && $self->priced_with_intraday_model;
}

sub _build_staking_limits {
    my $self = shift;

    my $underlying = $self->underlying;
    my $curr       = $self->currency;

    my $static     = BOM::Platform::Config::quants;
    my $bet_limits = $static->{bet_limits};
    # NOTE: this evaluates only the contract-specific payout limit. There may be further
    # client-specific restrictions which are evaluated in B:P::Transaction.
    my $per_contract_payout_limit = $static->{risk_profile}{$self->risk_profile->get_risk_profile}{payout}{$self->currency};
    my @possible_payout_maxes = ($bet_limits->{maximum_payout}->{$curr}, $per_contract_payout_limit);
    push @possible_payout_maxes, $bet_limits->{inefficient_period_payout_max}->{$self->currency} if $self->apply_market_inefficient_limit;

    my $payout_max = min(grep { looks_like_number($_) } @possible_payout_maxes);
    my $payout_min =
        ($self->underlying->market->name eq 'volidx')
        ? $bet_limits->{min_payout}->{volidx}->{$curr}
        : $bet_limits->{min_payout}->{default}->{$curr};
    my $stake_min = ($self->for_sale) ? $payout_min / 20 : $payout_min / 2;

    my $message_to_client_array;
    my $message_to_client;
    if ($self->for_sale) {
        $message_to_client = localize('Contract market price is too close to final payout.');
    } else {
        $message_to_client = localize(
            'Minimum stake of [_1] and maximum payout of [_2]',
            to_monetary_number_format($stake_min),
            to_monetary_number_format($payout_max));
        $message_to_client_array =
            ['Minimum stake of [_1] and maximum payout of [_2]', to_monetary_number_format($stake_min), to_monetary_number_format($payout_max)];
    }

    return {
        min                     => $stake_min,
        max                     => $payout_max,
        message_to_client       => $message_to_client,
        message_to_client_array => $message_to_client_array,
    };
}

sub _build_exit_tick {
    my $self = shift;

    my $underlying = $self->underlying;
    my $exit_tick;
    if ($self->tick_expiry) {
        my $tick_number       = $self->ticks_to_expiry;
        my @ticks_since_start = @{
            $underlying->ticks_in_between_start_limit({
                    start_time => $self->date_start->epoch + 1,
                    limit      => $tick_number,
                })};
        # We wait for the n-th tick to settle tick expiry contract.
        # But the maximum waiting period is 5 minutes.
        if (@ticks_since_start == $tick_number) {
            $exit_tick = $ticks_since_start[-1];
            $self->date_expiry(Date::Utility->new($exit_tick->epoch));
        }
    } elsif ($self->is_after_expiry and not $self->is_after_settlement) {
        # After expiry and yet pass the settlement, use current tick at the date_expiry
        # to determine the pre-settlement value. It might diff with actual settlement value
        $exit_tick = $underlying->tick_at($self->date_expiry->epoch, {allow_inconsistent => 1});
    } elsif ($self->expiry_daily or $self->date_expiry->is_same_as($self->calendar->closing_on($self->date_expiry))) {
        # Expiration based on daily OHLC
        $exit_tick = $underlying->closing_tick_on($self->date_expiry->date);
    } else {
        $exit_tick = $underlying->tick_at($self->date_expiry->epoch);
    }

    if ($self->entry_tick and $exit_tick) {
        my ($entry_tick_date, $exit_tick_date) = map { Date::Utility->new($_) } ($self->entry_tick->epoch, $exit_tick->epoch);
        if (    not $self->expiry_daily
            and $underlying->intradays_must_be_same_day
            and $self->calendar->trading_days_between($entry_tick_date, $exit_tick_date))
        {
            $self->_add_error({
                message => 'Exit tick date differs from entry tick date on intraday '
                    . "[symbol: "
                    . $underlying->symbol . "] "
                    . "[start: "
                    . $exit_tick_date->datetime . "] "
                    . "[expiry: "
                    . $entry_tick_date->datetime . "]",
                message_to_client => localize("Intraday contracts may not cross market open."),
            });
        }
    }

    return $exit_tick;
}

sub _build_risk_profile {
    my $self = shift;

    return BOM::Platform::RiskProfile->new(
        contract_category              => $self->category_code,
        expiry_type                    => $self->expiry_type,
        start_type                     => ($self->is_forward_starting ? 'forward' : 'spot'),
        currency                       => $self->currency,
        barrier_category               => $self->barrier_category,
        symbol                         => $self->underlying->symbol,
        market_name                    => $self->underlying->market->name,
        submarket_name                 => $self->underlying->submarket->name,
        underlying_risk_profile        => $self->underlying->risk_profile,
        underlying_risk_profile_setter => $self->underlying->risk_profile_setter,
    );
}

=head2 extra_info

get the extra pricing information of the contract. Is it necessary for Japan but let's do it for everyone.

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
        push @extra,
            (map { [($mapper{$_} // $_) => $self->$_] } qw(pricing_vol news_adjusted_pricing_vol long_term_prediction volatility_scaling_factor));
    } elsif ($self->pricing_vol_for_two_barriers) {
        push @extra, (map { [($mapper{$_} // $_) => $self->pricing_vol_for_two_barriers->{$_}] } qw(high_barrier_vol low_barrier_vol));
    } else {
        push @extra, [iv => $self->pricing_vol];
    }

    if ($as_type eq 'string') {
        my $string = join '_', map { $_->[1] } @extra;
        return $string;
    }

    return \@extra;
}

# Don't mind me, I just need to make sure my attibutes are available.
with 'BOM::Product::Role::Reportable';

no Moose;
__PACKAGE__->meta->make_immutable;

1;
