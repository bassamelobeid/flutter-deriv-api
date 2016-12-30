package BOM::Product::Contract;

use Moose;

require UNIVERSAL::require;

use MooseX::Role::Validatable::Error;
use Math::Function::Interpolator;
use Time::HiRes qw(time);
use List::Util qw(min max first);
use List::MoreUtils qw(none all);
use Scalar::Util qw(looks_like_number);
use Math::Util::CalculatedValue::Validatable;
use Date::Utility;
use Format::Util::Numbers qw(to_monetary_number_format roundnear);
use Time::Duration::Concise;

use Quant::Framework::Currency;
use Quant::Framework::VolSurface::Utils;
use Quant::Framework::EconomicEventCalendar;
use Postgres::FeedDB::Spot::Tick;
use Quant::Framework::CorrelationMatrix;

use Price::Calculator;
use Pricing::Engine::EuropeanDigitalSlope;
use Pricing::Engine::TickExpiry;
use Pricing::Engine::BlackScholes;

use BOM::System::Chronicle;

use BOM::Platform::Context qw(localize);

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use BOM::MarketData::VolSurface::Empirical;
use BOM::MarketData::Fetcher::VolSurface;

use BOM::Product::Contract::Category;
use BOM::Product::RiskProfile;
use BOM::Product::Types;
use BOM::Product::ContractValidator;
use LandingCompany::Offerings qw(get_contract_specifics);

use BOM::Market::DataDecimate;

# require Pricing:: modules to avoid circular dependency problems.
require BOM::Product::Pricing::Engine::Intraday::Forex;
require BOM::Product::Pricing::Engine::Intraday::Index;
require BOM::Product::Pricing::Engine::VannaVolga::Calibrated;
require BOM::Product::Pricing::Greeks::BlackScholes;

sub is_spread { return 0 }
sub is_legacy { return 0 }

has [qw(id pricing_code display_name sentiment other_side_code payout_type payouttime)] => (
    is      => 'ro',
    default => undef,
);

has debug_information => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_debug_information {
    my $self = shift;

    return $self->pricing_engine->can('debug_info') ? $self->pricing_engine->debug_info : {};
}

# Check whether the contract is expired or not . It is expired only if it passes the expiry time time and has valid exit tick
has is_expired => (
    is         => 'ro',
    lazy_build => 1,
);

# Check whether the contract is settelable or not. To be able to settle, it need pass the settlement time and has valid exit tick
has is_settleable => (
    is         => 'rw',
    lazy_build => 1,
);

has continue_price_stream => (
    is      => 'rw',
    default => 0
);

has missing_market_data => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0
);

has category => (
    is      => 'ro',
    isa     => 'bom_contract_category',
    coerce  => 1,
    handles => [qw(supported_expiries supported_start_types is_path_dependent allow_forward_starting two_barriers barrier_at_start)],
);

has category_code => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_category_code {
    my $self = shift;
    return $self->category->code;
}

has ticks_to_expiry => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_ticks_to_expiry {
    return shift->tick_count + 1;
}

# This is needed to determine if a contract is newly priced
# or it is repriced from an existing contract.
# Milliseconds matters since UI is reacting much faster now.
has _date_pricing_milliseconds => (
    is => 'rw',
);

has [qw(date_start date_settlement date_pricing effective_start)] => (
    is         => 'ro',
    isa        => 'date_object',
    lazy_build => 1,
    coerce     => 1,
);

sub _build_date_start {
    return Date::Utility->new;
}

# user supplied duration
has duration => (is => 'ro');

sub _build_date_pricing {
    my $self = shift;
    my $time = Time::HiRes::time();
    $self->_date_pricing_milliseconds($time);
    my $now = Date::Utility->new($time);
    return ($self->has_pricing_new and $self->pricing_new)
        ? $self->date_start
        : $now;
}

has date_expiry => (
    is       => 'rw',
    isa      => 'date_object',
    coerce   => 1,
    required => 1,
);

#backtest - Enable optimizations for speedier back testing.  Not suitable for production.
#tick_expiry - A boolean that indicates if a contract expires after a pre-specified number of ticks.

has [qw(backtest tick_expiry)] => (
    is      => 'ro',
    default => 0,
);

has basis_tick => (
    is         => 'ro',
    isa        => 'Postgres::FeedDB::Spot::Tick',
    lazy_build => 1,
);

sub _build_basis_tick {
    my $self = shift;

    my $waiting_for_entry_tick = localize('Waiting for entry tick.');
    my $missing_market_data    = localize('Trading on this market is suspended due to missing market data.');
    my ($basis_tick, $potential_error);

    # basis_tick is only set to entry_tick when the contract has started.
    if ($self->pricing_new) {
        $basis_tick = $self->current_tick;
        $potential_error = $self->starts_as_forward_starting ? $waiting_for_entry_tick : $missing_market_data;
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
        $self->add_error({
            message           => "Waiting for entry tick [symbol: " . $self->underlying->symbol . "]",
            message_to_client => $potential_error,
        });
    }

    return $basis_tick;
}

# This attribute tells us if this contract was initially bought as a forward starting contract.
# This should not be mistaken for is_forwarding_start attribute as that could change over time.
has starts_as_forward_starting => (
    is      => 'ro',
    default => 0,
);

#expiry_daily - Does this bet expire at close of the exchange?
has [
    qw( is_atm_bet expiry_daily is_intraday expiry_type start_type payouttime_code translated_display_name is_forward_starting permitted_expiries effective_daily_trading_seconds)
    ] => (
    is         => 'ro',
    lazy_build => 1,
    );

# Is this contract meant to be ATM or non ATM at start.
# The status will not change throughout the lifetime of the contract due to differences in offerings for ATM and non ATM contracts.
sub _build_is_atm_bet {
    my $self = shift;

    return 0 if $self->two_barriers;
    # if not defined, it is non ATM
    return 0 if not defined $self->supplied_barrier;
    return 0 if $self->supplied_barrier !~ /^S0P$/;
    return 1;
}

sub _build_expiry_daily {
    my $self = shift;
    return $self->is_intraday ? 0 : 1;
}

# daily trading seconds based on the market's trading hour
sub _build_effective_daily_trading_seconds {
    my $self                  = shift;
    my $date_expiry           = $self->date_expiry;
    my $calendar              = $self->calendar;
    my $daily_trading_seconds = $calendar->closing_on($date_expiry)->epoch - $calendar->opening_on($date_expiry)->epoch;

    return $daily_trading_seconds;
}

sub _build_is_intraday {
    my $self = shift;

    return $self->_check_is_intraday($self->effective_start);

}

sub _check_is_intraday {
    my ($self, $date_start) = @_;
    my $date_expiry       = $self->date_expiry;
    my $contract_duration = $date_expiry->epoch - $date_start->epoch;

    return 0 if $contract_duration > 86400;

    # for contract that start at the open of day and expire at the close of day (include early close) should be treated as daily contract
    my $closing = $self->calendar->closing_on($self->date_expiry);
    return 0 if $closing and $closing->is_same_as($self->date_expiry) and $contract_duration >= $self->effective_daily_trading_seconds;

    return 1;
}

sub _build_expiry_type {
    my $self = shift;

    return ($self->tick_expiry) ? 'tick' : ($self->expiry_daily) ? 'daily' : 'intraday';
}

sub _build_start_type {
    my $self = shift;
    return $self->is_forward_starting ? 'forward' : 'spot';
}

sub _build_payouttime_code {
    my $self = shift;

    return ($self->payouttime eq 'hit') ? 0 : 1;
}

sub _build_translated_display_name {
    my $self = shift;

    return unless ($self->display_name);
    return localize($self->display_name);
}

sub _build_is_forward_starting {
    my $self = shift;
    return ($self->allow_forward_starting and $self->date_pricing->is_before($self->date_start)) ? 1 : 0;
}

sub _build_permitted_expiries {
    my $self = shift;

    my $expiries_ref = $self->offering_specifics->{permitted};
    return $expiries_ref;
}

has [qw( pricing_engine_name )] => (
    is         => 'rw',
    isa        => 'Str',
    lazy_build => 1,
);

has pricing_engine => (
    is         => 'ro',
    lazy_build => 1,
);

has greek_engine => (
    is         => 'ro',
    isa        => 'BOM::Product::Pricing::Greeks',
    lazy_build => 1,
    handles    => [qw(delta vega theta gamma vanna volga)],
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

has currency => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has [qw( longcode shortcode )] => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

has payout => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

has value => (
    is      => 'rw',
    isa     => 'Num',
    default => 0,
);

has [
    qw(q_rate
        r_rate
        pricing_mu
        )
    ] => (
    is         => 'rw',
    lazy_build => 1,
    );

has [qw(entry_tick current_tick)] => (
    is         => 'ro',
    lazy_build => 1,
);

has [
    qw( bid_price
        theo_price
        bs_price
        )
    ] => (
    is         => 'ro',
    init_arg   => undef,
    lazy_build => 1,
    );

has ask_price => (
    is         => 'ro',
    lazy_build => 1,
);

has [
    qw(vol_at_strike
        entry_spot
        current_spot)
    ] => (
    is         => 'rw',
    isa        => 'Maybe[PositiveNum]',
    lazy_build => 1,
    );

#prediction (for tick trades) is what client predicted would happen
#tick_count is for tick trades

has [qw(prediction tick_count)] => (
    is  => 'ro',
    isa => 'Maybe[Num]',
);

# pricing_new - Do we believe this to be a new unsold bet starting now (or later)?

has [qw(
        pricing_new
        )
    ] => (
    is         => 'ro',
    isa        => 'Bool',
    lazy_build => 1,
    );

=item for_sale

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

=item max_tick_expiry_duration

A TimeInterval which expresses the maximum time a tick trade may run, even if there are missing ticks in the middle.

=cut

has max_tick_expiry_duration => (
    is      => 'ro',
    isa     => 'time_interval',
    default => '5m',
    coerce  => 1,
);

has [qw(pricing_args)] => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

has build_parameters => (
    is  => 'ro',
    isa => 'HashRef',
    # Required until it goes away entirely.
    required => 1,
);

has empirical_volsurface => (
    is         => 'ro',
    lazy_build => 1,
);

has [qw(volsurface)] => (
    is         => 'rw',
    isa        => 'Quant::Framework::VolSurface',
    lazy_build => 1,
);

# discounted_probability - The discounted total probability, given the time value of the money at stake.
# timeindays/timeinyears - note that for FX contracts of >=1 duration, these values will follow the market convention of integer days
has [qw(
        ask_probability
        theo_probability
        bid_probability
        discounted_probability
        timeinyears
        timeindays
        )
    ] => (
    is         => 'ro',
    isa        => 'Math::Util::CalculatedValue::Validatable',
    lazy_build => 1,
    );

#fixed_expiry - A Boolean to determine if this bet has fixed or flexible expiries.

has fixed_expiry => (
    is      => 'ro',
    default => 0,
);

has underlying => (
    is      => 'ro',
    isa     => 'underlying_object',
    coerce  => 1,
    handles => [qw(market pip_size)],
);

has calendar => (
    is      => 'ro',
    isa     => 'Quant::Framework::TradingCalendar',
    lazy    => 1,
    default => sub { return shift->underlying->calendar; },
);

has opposite_contract => (
    is         => 'ro',
    isa        => 'BOM::Product::Contract',
    lazy_build => 1
);

sub _build_date_settlement {
    my $self       = shift;
    my $end_date   = $self->date_expiry;
    my $underlying = $self->underlying;

    my $date_settlement = $end_date;    # Usually we settle when we expire.
    if ($self->expiry_daily and $self->calendar->trades_on($end_date)) {
        $date_settlement = $self->calendar->settlement_on($end_date);
    }

    return $date_settlement;
}

sub _build_effective_start {
    my $self = shift;

    return
          ($self->date_pricing->is_after($self->date_expiry)) ? $self->date_start
        : ($self->date_pricing->is_after($self->date_start))  ? $self->date_pricing
        :                                                       $self->date_start;
}

sub _build_greek_engine {
    my $self = shift;
    return BOM::Product::Pricing::Greeks::BlackScholes->new({bet => $self});
}

sub _build_pricing_engine_name {
    my $self = shift;

    my $engine_name = $self->is_path_dependent ? 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated' : 'Pricing::Engine::EuropeanDigitalSlope';

    #For Volatility indices, we use plain BS formula for pricing instead of VV/Slope
    $engine_name = 'Pricing::Engine::BlackScholes' if $self->market->name eq 'volidx';

    if ($self->tick_expiry) {
        my @symbols = create_underlying_db->get_symbols_for(
            market            => 'forex',     # forex is the only financial market that offers tick expiry contracts for now.
            contract_category => 'callput',
            expiry_type       => 'tick',
        );
        $engine_name = 'Pricing::Engine::TickExpiry' if _match_symbol(\@symbols, $self->underlying->symbol);
    } elsif (
        $self->is_intraday and not $self->is_forward_starting and grep {
            $self->market->name eq $_
        } qw(forex indices commodities)
        )
    {
        my $func = (first { $self->market->name eq $_ } qw(forex commodities)) ? 'symbols_for_intraday_fx' : 'symbols_for_intraday_index';
        my @symbols = create_underlying_db->$func;
        if (_match_symbol(\@symbols, $self->underlying->symbol) and my $loc = $self->offering_specifics->{historical}) {
            my $duration = $self->remaining_time;
            my $name = $self->market->name eq 'indices' ? 'Index' : 'Forex';
            $engine_name = 'BOM::Product::Pricing::Engine::Intraday::' . $name
                if ((defined $loc->{min} and defined $loc->{max})
                and $duration->seconds <= $loc->{max}->seconds
                and $duration->seconds >= $loc->{min}->seconds);
        }
    }

    return $engine_name;
}

sub _match_symbol {
    my ($lists, $symbol) = @_;
    for (@$lists) {
        return 1 if $_ eq $symbol;
    }
    return;
}

sub _market_convention {
    my $self = shift;

    return {
        get_rollover_time => sub {
            my $when = shift;
            return Quant::Framework::VolSurface::Utils->new->NY1700_rollover_date_on($when);
        },
    };
}

sub _create_new_interface_engine {
    my $self = shift;
    return if not $self->new_interface_engine;

    my %pricing_parameters;

    if ($self->pricing_engine_name eq 'Pricing::Engine::Digits') {
        %pricing_parameters = (
            strike => $self->barrier ? $self->barrier->as_absolute : undef,
            contract_type => $self->pricing_code,
        );
    } elsif ($self->pricing_engine_name eq 'Pricing::Engine::TickExpiry') {
        my $backprice = ($self->underlying->for_date) ? 1 : 0;
        %pricing_parameters = (
            contract_type     => $self->pricing_code,
            underlying_symbol => $self->underlying->symbol,
            date_start        => $self->effective_start,
            date_pricing      => $self->date_pricing,
            ticks             => BOM::Market::DataDecimate->new()->tick_cache_get_num_ticks({
                    underlying => $self->underlying,
                    end_epoch  => $self->date_start->epoch,
                    num        => 20,
                    backprice  => $backprice,
                }
            ),
            economic_events => _generate_market_data($self->underlying, $self->date_start)->{economic_events},
        );
    } elsif ($self->pricing_engine_name eq 'Pricing::Engine::EuropeanDigitalSlope') {
        #pricing_vol can be calculated using an empirical vol. So we have to sent the raw numberc
        %pricing_parameters = (
            contract_type            => $self->pricing_code,
            for_date                 => $self->underlying->for_date,
            spot                     => $self->pricing_spot,
            strikes                  => [grep { $_ } values %{$self->barriers_for_pricing}],
            date_start               => $self->effective_start,
            chronicle_reader         => BOM::System::Chronicle::get_chronicle_reader($self->underlying->for_date),
            date_pricing             => $self->date_pricing,
            date_expiry              => $self->date_expiry,
            discount_rate            => $self->discount_rate,
            mu                       => $self->mu,
            vol                      => $self->pricing_vol_for_two_barriers // $self->pricing_vol,
            payouttime_code          => $self->payouttime_code,
            q_rate                   => $self->q_rate,
            r_rate                   => $self->r_rate,
            priced_with              => $self->priced_with,
            underlying_symbol        => $self->underlying->symbol,
            volsurface               => $self->volsurface->surface,
            volsurface_recorded_date => $self->volsurface->recorded_date,
        );
    } elsif ($self->pricing_engine_name eq 'Pricing::Engine::BlackScholes') {
        %pricing_parameters = (
            strikes         => [grep { $_ } values %{$self->barriers_for_pricing}],
            spot            => $self->pricing_spot,
            t               => $self->timeinyears->amount,
            discount_rate   => $self->discount_rate,
            mu              => $self->mu,
            payouttime_code => $self->payouttime_code,
            payout_type     => $self->payout_type,
            contract_type   => $self->pricing_code,
            vol => $self->pricing_vol_for_two_barriers // $self->pricing_vol,
        );
    } else {
        die "Unknown pricing engine: " . $self->pricing_engine_name;
    }

    if (my @missing_parameters = grep { !exists $pricing_parameters{$_} } @{$self->pricing_engine_name->required_args}) {
        die "Missing pricing parameters for engine " . $self->pricing_engine_name . " - " . join ',', @missing_parameters;
    }

    return $self->pricing_engine_name->new(%pricing_parameters);
}

sub _build_pricing_engine {
    my $self = shift;

    return $self->_create_new_interface_engine if $self->new_interface_engine;

    my $pricing_engine = $self->pricing_engine_name->new({
        bet                     => $self,
        apply_bounceback_safety => !$self->for_sale,
        inefficient_period      => $self->market_is_inefficient,
        $self->priced_with_intraday_model ? (economic_events => $self->economic_events_for_volatility_calculation) : (),
    });

    return $pricing_engine;
}

has remaining_time => (
    is         => 'ro',
    isa        => 'Time::Duration::Concise',
    lazy_build => 1,
);

sub _build_remaining_time {
    my $self = shift;

    my $when = ($self->date_pricing->is_after($self->date_start)) ? $self->date_pricing : $self->date_start;

    return $self->get_time_to_expiry({
        from => $when,
    });
}

sub _build_r_rate {
    my $self = shift;

    return $self->underlying->interest_rate_for($self->timeinyears->amount);
}

sub _build_q_rate {
    my $self = shift;

    my $underlying = $self->underlying;
    my $q_rate     = $underlying->dividend_rate_for($self->timeinyears->amount);

    my $rate;
    if ($underlying->market->prefer_discrete_dividend) {
        $rate = 0;
    } else {
        $rate = $q_rate;
    }

    return $rate;
}

sub _build_current_spot {
    my $self = shift;

    my $spot = $self->current_tick;

    return ($spot) ? $self->underlying->pipsized_value($spot->quote) : undef;
}

sub _build_entry_spot {
    my $self = shift;

    return ($self->entry_tick) ? $self->entry_tick->quote : undef;
}

sub _build_current_tick {
    my $self = shift;

    return $self->underlying->spot_tick;
}

sub _build_pricing_new {
    my $self = shift;

    # do not use $self->date_pricing here because milliseconds matters!
    # _date_pricing_milliseconds will not be set if date_pricing is not built.
    my $time = $self->_date_pricing_milliseconds // $self->date_pricing->epoch;
    return 0 if $time > $self->date_start->epoch;
    return 1;
}

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

# we use pricing_engine_name matching all the time.
has priced_with_intraday_model => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_priced_with_intraday_model',
);

sub _build_priced_with_intraday_model {
    my $self = shift;

    # Intraday::Index is just a flat price + commission, so it is not considered as a model.
    return ($self->pricing_engine_name eq 'BOM::Product::Pricing::Engine::Intraday::Forex');
}

sub _build_opposite_contract {
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

    my $opp_contract = $self->_produce_contract_ref->(\%opp_parameters);

    if (my $role = $opp_parameters{role}) {
        $role->require;
        $role->meta->apply($opp_contract);
    }

    return $opp_contract;
}

sub _build_empirical_volsurface {
    my $self = shift;
    return BOM::MarketData::VolSurface::Empirical->new(underlying => $self->underlying);
}

sub _build_volsurface {
    my $self = shift;

    # Due to the craziness we have in volsurface cutoff. This complexity is needed!
    # FX volsurface has cutoffs at either 21:00 or 23:59 or the early close time.
    # Index volsurfaces shouldn't have cutoff concept. But due to the system design, an index surface cuts at the close of trading time on a non-DST day.
    my %submarkets = (
        major_pairs => 1,
        minor_pairs => 1
    );
    my $vol_utils = Quant::Framework::VolSurface::Utils->new;
    my $cutoff_str;
    if ($submarkets{$self->underlying->submarket->name}) {
        my $calendar       = $self->calendar;
        my $effective_date = $vol_utils->effective_date_for($self->date_pricing);
        $effective_date = $calendar->trades_on($effective_date) ? $effective_date : $calendar->trade_date_after($effective_date);
        my $cutoff_date = $calendar->closing_on($effective_date);

        $cutoff_str = $cutoff_date->time_cutoff;
    }

    return $self->_volsurface_fetcher->fetch_surface({
        underlying => $self->underlying,
        (defined $cutoff_str) ? (cutoff => $cutoff_str) : (),
    });
}

sub _build_pricing_mu {
    my $self = shift;

    return $self->mu;
}

=head2 _build_longcode

Returns the (localized) longcode for this contract.

May throw an exception if an invalid expiry type is requested for this contract type.

=cut

sub _build_longcode {
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

=item is_after_settlement

This check if the contract already passes the settlement time

For tick expiry contract, it can expires when a certain number of ticks is received or it already passes the max_tick_expiry_duration.
For other contracts, it can expires when current time has past a pre-determined settelement time.

=back

=cut

sub is_after_settlement {
    my $self = shift;

    if ($self->tick_expiry) {
        return 1
            if ($self->exit_tick || ($self->date_pricing->epoch - $self->date_start->epoch > $self->max_tick_expiry_duration->seconds));
    } else {
        return 1 if $self->get_time_to_settlement->seconds == 0;
    }

    return 0;
}

=item is_after_expiry

This check if the contract already passes the expiry times

For tick expiry contract, there is no expiry time, so it will check again the exit tick
For other contracts, it will check the remaining time of the contract to expiry.
=back

=cut

sub is_after_expiry {
    my $self = shift;

    if ($self->tick_expiry) {
        return 1
            if ($self->exit_tick || ($self->date_pricing->epoch - $self->date_start->epoch > $self->max_tick_expiry_duration->seconds));
    } else {

        return 1 if $self->get_time_to_expiry->seconds == 0;
    }
    return 0;
}

sub may_settle_automatically {
    my $self = shift;

    # For now, only trigger this condition when the bet is past expiry.
    return (not $self->get_time_to_settlement->seconds and not $self->is_valid_to_sell) ? 0 : 1;
}

has corporate_actions => (
    is         => 'ro',
    lazy_build => 1,
);

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

=head2 otm_threshold

An abbreviation for deep out of the money threshold. This is used to floor and cap prices.

=cut

has otm_threshold => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_otm_threshold {
    my $self = shift;

    return $self->market->deep_otm_threshold;
}

has price_calculator => (
    is         => 'ro',
    isa        => 'Price::Calculator',
    lazy_build => 1,
);

sub _build_price_calculator {
    my $self = shift;

    my $market_name             = $self->market->name;
    my $per_market_scaling      = BOM::Platform::Runtime->instance->app_config->quants->commission->adjustment->per_market_scaling;
    my $base_commission_scaling = $per_market_scaling->$market_name;

    return Price::Calculator->new({
            currency                => $self->currency,
            deep_otm_threshold      => $self->otm_threshold,
            base_commission_scaling => $base_commission_scaling,
            app_markup_percentage   => $self->app_markup_percentage,
            ($self->has_base_commission)
            ? (base_commission => $self->base_commission)
            : (underlying_base_commission => $self->underlying->base_commission),
            ($self->has_commission_markup)      ? (commission_markup      => $self->commission_markup)      : (),
            ($self->has_commission_from_stake)  ? (commission_from_stake  => $self->commission_from_stake)  : (),
            ($self->has_payout)                 ? (payout                 => $self->payout)                 : (),
            ($self->has_ask_price)              ? (ask_price              => $self->ask_price)              : (),
            ($self->has_theo_probability)       ? (theo_probability       => $self->theo_probability)       : (),
            ($self->has_ask_probability)        ? (ask_probability        => $self->ask_probability)        : (),
            ($self->has_discounted_probability) ? (discounted_probability => $self->discounted_probability) : (),
        });
}

my $pc_params_setters = {
    timeinyears            => sub { my $self = shift; $self->price_calculator->timeinyears($self->timeinyears) },
    discount_rate          => sub { my $self = shift; $self->price_calculator->discount_rate($self->discount_rate) },
    staking_limits         => sub { my $self = shift; $self->price_calculator->staking_limits($self->staking_limits) },
    theo_probability       => sub { my $self = shift; $self->price_calculator->theo_probability($self->theo_probability) },
    commission_markup      => sub { my $self = shift; $self->price_calculator->commission_markup($self->commission_markup) },
    commission_from_stake  => sub { my $self = shift; $self->price_calculator->commission_from_stake($self->commission_from_stake) },
    discounted_probability => sub { my $self = shift; $self->price_calculator->discounted_probability($self->discounted_probability) },
    probability            => sub {
        my $self = shift;
        my $probability;
        if ($self->new_interface_engine) {
            $probability = Math::Util::CalculatedValue::Validatable->new({
                name        => 'theo_probability',
                description => 'theoretical value of a contract',
                set_by      => $self->pricing_engine_name,
                base_amount => $self->pricing_engine->theo_probability,
                minimum     => 0,
                maximum     => 1,
            });
        } else {
            $probability = $self->pricing_engine->probability;
        }
        $self->price_calculator->theo_probability($probability);
    },
    opposite_ask_probability => sub {
        my $self = shift;
        $self->price_calculator->opposite_ask_probability($self->opposite_contract->ask_probability);
    },
};

my $pc_needed_params_map = {
    theo_probability       => [qw/ probability /],
    ask_probability        => [qw/ theo_probability /],
    bid_probability        => [qw/ theo_probability discounted_probability opposite_ask_probability /],
    payout                 => [qw/ theo_probability commission_from_stake /],
    commission_markup      => [qw/ theo_probability /],
    commission_from_stake  => [qw/ theo_probability commission_markup /],
    validate_price         => [qw/ theo_probability commission_markup commission_from_stake staking_limits /],
    discounted_probability => [qw/ timeinyears discount_rate /],
};

sub _set_price_calculator_params {
    my ($self, $method) = @_;

    for my $key (@{$pc_needed_params_map->{$method}}) {
        $pc_params_setters->{$key}->($self);
    }
    return;
}

# We adopt "near-far" methodology to price in dividends by adjusting spot and strike.
# This returns a hash reference with spot and barrrier adjustment for the bet period.

has dividend_adjustment => (
    is         => 'ro',
    lazy_build => 1,
);

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

    if (scalar @corporate_actions and (first { Date::Utility->new($_->{effective_date})->is_after($dividend_recorded_date) } @corporate_actions)) {

        $self->add_error({
            message => 'Dividend is not updated  after corporate action'
                . "[dividend recorded date : "
                . $dividend_recorded_date->datetime . "] "
                . "[symbol: "
                . $self->underlying->symbol . "]",
            message_to_client => localize('Trading on this market is suspended due to missing market data.'),
        });

    }

    return $dividend_adjustment;

}

sub _build_discounted_probability {
    my $self = shift;

    $self->_set_price_calculator_params('discounted_probability');
    return $self->price_calculator->discounted_probability;
}

sub _build_bid_probability {
    my $self = shift;

    $self->_set_price_calculator_params('bid_probability');
    return $self->price_calculator->bid_probability;
}

sub _build_bid_price {
    my $self = shift;

    return $self->_price_from_prob('bid_probability');
}

sub _build_ask_probability {
    my $self = shift;

    $self->_set_price_calculator_params('ask_probability');
    return $self->price_calculator->ask_probability;
}

sub _price_from_prob {
    my ($self, $prob) = @_;
    if ($self->date_pricing->is_after($self->date_start) and $self->is_expired) {
        $self->price_calculator->value($self->value);
    } else {

        $self->_set_price_calculator_params($prob);
    }
    return $self->price_calculator->price_from_prob($prob);
}

sub _build_ask_price {
    my $self = shift;

    return $self->_price_from_prob('ask_probability');
}

sub _build_payout {
    my ($self) = @_;

    $self->_set_price_calculator_params('payout');
    return $self->price_calculator->payout;
}

sub commission_multiplier {
    return shift->price_calculator->commission_multiplier(@_);
}

sub _build_theo_probability {
    my $self = shift;

    $self->_set_price_calculator_params('theo_probability');
    return $self->price_calculator->theo_probability;
}

# Application developer's commission.
# Defaults to 0%
has app_markup_percentage => (
    is      => 'ro',
    default => 0,
);

has [qw(app_markup_dollar_amount app_markup)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_app_markup {
    return shift->price_calculator->app_markup;
}

sub _build_app_markup_dollar_amount {
    my $self = shift;

    return roundnear(0.01, $self->app_markup->amount * $self->payout);
}

# base_commission can be overridden on contract type level.
# When this happens, underlying base_commission is ignored.
has [qw(risk_markup commission_markup base_commission commission_from_stake)] => (
    is         => 'ro',
    lazy_build => 1,
);

#this is supposed to be called for legacy pricing engines (not new interface)
sub _build_risk_markup {
    my $self = shift;

    my $base_amount = 0;
    if ($self->pricing_engine and $self->pricing_engine->can('risk_markup')) {
        $base_amount = $self->new_interface_engine ? $self->pricing_engine->risk_markup : $self->pricing_engine->risk_markup->amount;
    } elsif ($self->new_interface_engine) {
        $base_amount = $self->debug_information->{risk_markup}->{amount};
    }

    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'risk_markup',
        description => 'Risk markup for a pricing model',
        set_by      => $self->pricing_engine_name,
        base_amount => $base_amount,
    });
}

sub _build_base_commission {
    my $self = shift;

    return $self->price_calculator->base_commission;
}

sub _build_commission_markup {
    my $self = shift;

    $self->_set_price_calculator_params('commission_markup');
    return $self->price_calculator->commission_markup;
}

sub _build_commission_from_stake {
    my $self = shift;

    $self->_set_price_calculator_params('commission_from_stake');
    return $self->price_calculator->commission_from_stake;
}

sub _build_theo_price {
    my $self = shift;

    return $self->_price_from_prob('theo_probability');
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

# End of builders.

=head1 METHODS

=cut

# The pricing, greek and markup engines need the same set of arguments,
# so we provide this helper function which pulls all the revelant bits out of the object and
# returns a nice HashRef for them.
sub _build_pricing_args {
    my $self = shift;

    my $start_date           = $self->date_pricing;
    my $barriers_for_pricing = $self->barriers_for_pricing;
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
        payouttime_code => $self->payouttime_code,
    };

    if ($self->priced_with_intraday_model) {
        $args->{long_term_prediction}      = $self->empirical_volsurface->long_term_prediction;
        $args->{volatility_scaling_factor} = $self->empirical_volsurface->volatility_scaling_factor;
        $args->{iv_with_news}              = $self->news_adjusted_pricing_vol;
    }

    return $args;
}

has [qw(pricing_vol news_adjusted_pricing_vol)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_pricing_vol {
    my $self = shift;

    my $vol;
    my $volatility_error;
    if ($self->priced_with_intraday_model) {
        my $volsurface       = $self->empirical_volsurface;
        my $duration_seconds = $self->timeindays->amount * 86400;
        # volatility doesn't matter for less than 10 minutes ATM contracts,
        # where the intraday_delta_correction is the bounceback which is a function of trend, not volatility.
        my $uses_flat_vol = ($self->is_atm_bet and $duration_seconds < 10 * 60) ? 1 : 0;
        $vol = $volsurface->get_volatility({
            fill_cache            => !$self->backtest,
            current_epoch         => $self->date_pricing->epoch,
            seconds_to_expiration => $duration_seconds,
            economic_events       => $self->economic_events_for_volatility_calculation,
            uses_flat_vol         => $uses_flat_vol,
        });
        $volatility_error = $volsurface->error if $volsurface->error;
    } else {
        if ($self->pricing_engine_name =~ /VannaVolga/) {
            $vol = $self->volsurface->get_volatility({
                from  => $self->effective_start,
                to    => $self->date_expiry,
                delta => 50
            });
        } else {
            $vol = $self->vol_at_strike;
        }
        # we might get an error while pricing contract, take care of them here.
        $volatility_error = $self->volsurface->validation_error if $self->volsurface->validation_error;
    }

    if ($volatility_error) {
        $self->add_error({
            message           => $volatility_error,
            message_to_client => localize('Trading on this market is suspended due to missing market data.'),
        });
    }

    if ($vol <= 0) {
        $self->add_error({
            message           => 'Zero volatility. Invalidate price.',
            message_to_client => localize('We could not process this contract at this time.'),
        });
    }

    return $vol;
}

has economic_events_for_volatility_calculation => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_economic_events_for_volatility_calculation {
    my $self = shift;

    my $all_events        = $self->applicable_economic_events;
    my $effective_start   = $self->effective_start;
    my $seconds_to_expiry = $self->get_time_to_expiry({from => $effective_start})->seconds;
    my $current_epoch     = $effective_start->epoch;
    # Go back another hour because we expect the maximum impact on any news would not last for more than an hour.
    my $start = $current_epoch - $seconds_to_expiry - 3600;
    # Plus 5 minutes for the shifting logic.
    # If news occurs 5 minutes before/after the contract expiration time, we shift the news triangle to 5 minutes before the contract expiry.
    my $end = $current_epoch + $seconds_to_expiry + 300;

    return [grep { $_->{release_date} >= $start and $_->{release_date} <= $end and $_->{impact} > 1 } @$all_events];
}

has applicable_economic_events => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_applicable_economic_events',
);

sub _build_applicable_economic_events {
    my $self = shift;

    my $effective_start   = $self->effective_start;
    my $seconds_to_expiry = $self->get_time_to_expiry({from => $effective_start})->seconds;
    my $current_epoch     = $effective_start->epoch;
    # Go back and forward an hour to get all the tentative events.
    my $start = $current_epoch - $seconds_to_expiry - 3600;
    my $end   = $current_epoch + $seconds_to_expiry + 3600;

    return Quant::Framework::EconomicEventCalendar->new({
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader($self->underlying->for_date),
        }
        )->get_latest_events_for_period({
            from => Date::Utility->new($start),
            to   => Date::Utility->new($end)});
}

has tentative_events => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_tentative_events {
    my $self = shift;

    my %affected_currency = (
        $self->underlying->asset_symbol           => 1,
        $self->underlying->quoted_currency_symbol => 1,
    );
    return [grep { $_->{is_tentative} and $affected_currency{$_->{symbol}} } @{$self->applicable_economic_events}];
}

sub _build_news_adjusted_pricing_vol {
    my $self = shift;

    my $news_adjusted_vol = $self->pricing_vol;
    my $effective_start   = $self->effective_start;
    my $seconds_to_expiry = $self->get_time_to_expiry({from => $effective_start})->seconds;
    my $events            = $self->economic_events_for_volatility_calculation;

    # Only recalculated if there's economic_events.
    if ($seconds_to_expiry > 10 and @$events) {
        $news_adjusted_vol = $self->empirical_volsurface->get_volatility({
            fill_cache            => !$self->backtest,
            current_epoch         => $effective_start->epoch,
            seconds_to_expiration => $seconds_to_expiry,
            economic_events       => $events,
            include_news_impact   => 1,
        });
    }

    return $news_adjusted_vol;
}

sub _build_vol_at_strike {
    my $self = shift;

    #If surface is flat, don't bother calculating all those arguments
    return $self->volsurface->get_volatility if ($self->underlying->volatility_surface_type eq 'flat');

    my $pricing_spot = $self->pricing_spot;
    my $vol_args     = {
        strike => $self->barriers_for_pricing->{barrier1},
        q_rate => $self->q_rate,
        r_rate => $self->r_rate,
        spot   => $pricing_spot,
        from   => $self->effective_start,
        to     => $self->date_expiry,
    };

    if ($self->two_barriers) {
        $vol_args->{strike} = $pricing_spot;
    }

    return $self->volsurface->get_volatility($vol_args);
}

# pricing_spot - The spot used in pricing.  It may have been adjusted for corporate actions.
has pricing_spot => (
    is         => 'ro',
    lazy_build => 1,
);

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
        $self->add_error({
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

has [qw(offering_specifics barrier_category)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_offering_specifics {
    my $self = shift;

    return get_contract_specifics(
        BOM::Platform::Runtime->instance->get_offerings_config,
        {
            underlying_symbol => $self->underlying->symbol,
            barrier_category  => $self->barrier_category,
            expiry_type       => $self->expiry_type,
            start_type        => $self->start_type,
            contract_category => $self->category->code,
        });
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

has apply_market_inefficient_limit => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_apply_market_inefficient_limit {
    my $self = shift;

    return $self->market_is_inefficient && $self->priced_with_intraday_model;
}

has 'staking_limits' => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build_staking_limits {
    my $self = shift;

    my $underlying = $self->underlying;
    my $curr       = $self->currency;

    my $static     = BOM::System::Config::quants;
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

# Rates calculation, including quanto effects.

has [qw(mu discount_rate)] => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

has [qw(domqqq forqqq fordom)] => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

has priced_with => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

has [qw(atm_vols rho)] => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1
);

# a hash reference for slow migration of pricing engine to the new interface.
has new_interface_engine => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_new_interface_engine',
);

sub _build_new_interface_engine {
    my $self = shift;

    my %engines = (
        'Pricing::Engine::BlackScholes'         => 1,
        'Pricing::Engine::Digits'               => 1,
        'Pricing::Engine::TickExpiry'           => 1,
        'Pricing::Engine::EuropeanDigitalSlope' => 1,
    );

    return $engines{$self->pricing_engine_name} // 0;
}

# For European::Slope engine, we need call and put vol for double barriers contract
has pricing_vol_for_two_barriers => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_pricing_vol_for_two_barriers',
);

sub _build_pricing_vol_for_two_barriers {
    my $self = shift;

    return if not $self->two_barriers;
    return if $self->pricing_engine_name ne 'Pricing::Engine::EuropeanDigitalSlope';

    my $vol_args = {
        from => $self->date_start,
        to   => $self->date_expiry,
    };

    $vol_args->{strike} = $self->barriers_for_pricing->{barrier1};
    my $high_barrier_vol = $self->volsurface->get_volatility($vol_args);

    $vol_args->{strike} = $self->barriers_for_pricing->{barrier2};
    my $low_barrier_vol = $self->volsurface->get_volatility($vol_args);

    return {
        high_barrier_vol => $high_barrier_vol,
        low_barrier_vol  => $low_barrier_vol
    };
}

sub _generate_market_data {
    my ($underlying, $date_start) = @_;

    my $for_date = $underlying->for_date;
    my $result   = {};

    #this is a list of symbols which are applicable when getting important economic events.
    #Note that other than currency pair of the fx symbol, we include some other important currencies
    #here because any event for these currencies, can potentially affect all other currencies too
    my %applicable_symbols = (
        USD                                 => 1,
        AUD                                 => 1,
        CAD                                 => 1,
        CNY                                 => 1,
        NZD                                 => 1,
        $underlying->quoted_currency_symbol => 1,
        $underlying->asset_symbol           => 1,
    );

    my $ee = Quant::Framework::EconomicEventCalendar->new({
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader($for_date),
        }
        )->get_latest_events_for_period({
            from => $date_start->minus_time_interval('10m'),
            to   => $date_start->plus_time_interval('10m')});

    my @applicable_news =
        sort { $a->{release_date} <=> $b->{release_date} } grep { $applicable_symbols{$_->{symbol}} } @$ee;

    #as of now, we only update the result with a raw list of economic events, later that we move to other
    #engines, we will add other market-data items too (e.g. dividends, vol-surface, ...)
    $result->{economic_events} = \@applicable_news;
    return $result;
}

sub _market_data {
    my $self = shift;

    # market data date is determined by for_date in underlying.
    my $for_date        = $self->underlying->for_date;
    my %underlyings     = ($self->underlying->symbol => $self->underlying);
    my $volsurface      = $self->volsurface;
    my $effective_start = $self->effective_start;
    my $date_expiry     = $self->date_expiry;
    return {
        get_vol_spread => sub {
            my $args = shift;
            return $volsurface->get_spread($args);
        },
        get_volsurface_data => sub {
            return $volsurface->surface;
        },
        get_market_rr_bf => sub {
            my $timeindays = shift;
            return $volsurface->get_market_rr_bf($timeindays);
        },
        get_volatility => sub {
            my ($args, $surface_data) = @_;
            # if there's new surface data, calculate vol from that.
            my $vol;
            if ($surface_data) {
                my $new_volsurface_obj = $volsurface->clone({surface_data => $surface_data});
                $vol = $new_volsurface_obj->get_volatility($args);
            } else {
                $vol = $volsurface->get_volatility($args);
            }

            return $vol;
        },
        get_atm_volatility => sub {
            my $args = shift;

            $args->{delta} = 50;
            my $vol = $volsurface->get_volatility($args);

            return $vol;
        },
        get_economic_event => sub {
            my $args = shift;
            my $underlying = $underlyings{$args->{underlying_symbol}} // create_underlying({
                symbol   => $args->{underlying_symbol},
                for_date => $for_date
            });
            my ($from, $to) = map { Date::Utility->new($args->{$_}) } qw(start end);
            my %applicable_symbols = (
                USD                                 => 1,
                AUD                                 => 1,
                CAD                                 => 1,
                CNY                                 => 1,
                NZD                                 => 1,
                $underlying->quoted_currency_symbol => 1,
                $underlying->asset_symbol           => 1,
            );

            my $ee = Quant::Framework::EconomicEventCalendar->new({
                    chronicle_reader => BOM::System::Chronicle::get_chronicle_reader($for_date),
                }
                )->get_latest_events_for_period({
                    from => $from,
                    to   => $to
                });

            my @applicable_news =
                sort { $a->{release_date} <=> $b->{release_date} } grep { $applicable_symbols{$_->{symbol}} } @$ee;

            return @applicable_news;
        },
        get_ticks => sub {
            my $args              = shift;
            my $underlying_symbol = delete $args->{underlying_symbol};
            $args->{underlying} = $underlyings{$underlying_symbol} // create_underlying({
                symbol   => $underlying_symbol,
                for_date => $for_date
            });

            my $backprice = ($args->{underlying}->for_date) ? 1 : 0;

            return BOM::Market::DataDecimate->new()->tick_cache_get_num_ticks({
                underlying => $args->{underlying},
                end_epoch  => $args->{ending_epoch},
                num        => $args->{tick_count},
                backprice  => $backprice,
            });
        },
        get_overnight_tenor => sub {
            return $volsurface->_ON_day;
        },
    };
}

sub _build_priced_with {
    my $self = shift;

    my $underlying = $self->underlying;

    # Everything should have a quoted currency, except our randoms.
    # However, rather than check for random directly, just do a numeraire bet if we don't know what it is.
    my $priced_with;
    if ($underlying->quoted_currency_symbol eq $self->currency or (none { $underlying->market->name eq $_ } (qw(forex commodities indices)))) {
        $priced_with = 'numeraire';
    } elsif ($underlying->asset_symbol eq $self->currency) {
        $priced_with = 'base';
    } else {
        $priced_with = 'quanto';
    }

    if ($underlying->submarket->name eq 'smart_fx') {
        $priced_with = 'numeraire';
    }

    return $priced_with;
}

sub _build_mu {
    my $self = shift;

    my $mu = $self->r_rate - $self->q_rate;

    if (first { $self->underlying->market->name eq $_ } (qw(forex commodities indices))) {
        my $rho = $self->rho->{fd_dq};
        my $vol = $self->atm_vols;
        # See [1] for Quanto Formula
        $mu = $self->r_rate - $self->q_rate - $rho * $vol->{fordom} * $vol->{domqqq};
    }

    return $mu;
}

sub _build_rho {

    my $self     = shift;
    my $atm_vols = $self->atm_vols;
    my $w        = ($self->domqqq->{underlying}->inverted) ? -1 : 1;

    my %rhos;

    $rhos{fd_dq} = 0;

    if ($self->priced_with eq 'numeraire') {
        $rhos{fd_dq} = 0;
    } elsif ($self->priced_with eq 'base') {
        $rhos{fd_dq} = -1;
    } elsif ($self->underlying->market->name eq 'forex' or $self->underlying->market->name eq 'commodities') {
        $rhos{fd_dq} =
            $w * (($atm_vols->{forqqq}**2 - $atm_vols->{fordom}**2 - $atm_vols->{domqqq}**2) / (2 * $atm_vols->{fordom} * $atm_vols->{domqqq}));
    } elsif ($self->underlying->market->name eq 'indices') {
        my $construct_args = {
            symbol           => $self->underlying->market->name,
            for_date         => $self->underlying->for_date,
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader($self->underlying->for_date),
        };
        my $rho_data = Quant::Framework::CorrelationMatrix->new($construct_args);

        my $index           = $self->underlying->asset_symbol;
        my $payout_currency = $self->currency;
        my $tiy             = $self->timeinyears->amount;
        my $correlation_u   = create_underlying($index);

        $rhos{fd_dq} = $rho_data->correlation_for($index, $payout_currency, $tiy, $correlation_u->expiry_conventions);
    }

    return \%rhos;
}

has _volsurface_fetcher => (
    is         => 'ro',
    isa        => 'BOM::MarketData::Fetcher::VolSurface',
    init_arg   => undef,
    lazy_build => 1,
);

sub _build__volsurface_fetcher {
    return BOM::MarketData::Fetcher::VolSurface->new;
}

sub _vols_at_point {
    my ($self, $end_date, $days_attr) = @_;

    my $vol_args = {
        delta => 50,
        from  => $self->effective_start,
        to    => $self->date_expiry,
    };

    my $market_name = $self->underlying->market->name;
    my %vols_to_use;
    foreach my $pair (qw(fordom domqqq forqqq)) {
        my $pair_ref = $self->$pair;
        $pair_ref->{volsurface} //= $self->_volsurface_fetcher->fetch_surface({
            underlying => $pair_ref->{underlying},
        });
        $pair_ref->{vol} //= $pair_ref->{volsurface}->get_volatility($vol_args);
        $vols_to_use{$pair} = $pair_ref->{vol};
    }

    if (none { $market_name eq $_ } (qw(forex commodities indices))) {
        $vols_to_use{domqqq} = $vols_to_use{fordom};
        $vols_to_use{forqqq} = $vols_to_use{domqqq};
    }

    return \%vols_to_use;
}

sub _build_atm_vols {
    my $self = shift;

    return $self->_vols_at_point($self->date_expiry, 'timeindays');
}

sub _build_domqqq {
    my $self = shift;

    my $result = {};

    if ($self->priced_with eq 'quanto') {
        $result->{underlying} = create_underlying({
            symbol   => 'frx' . $self->underlying->quoted_currency_symbol . $self->currency,
            for_date => $self->underlying->for_date
        });
        $result->{volsurface} = $self->_volsurface_fetcher->fetch_surface({
            underlying => $result->{underlying},
        });
    } else {
        $result = $self->fordom;
    }

    return $result;
}

sub _build_forqqq {
    my $self = shift;

    my $result = {};

    if ($self->priced_with eq 'quanto' and ($self->underlying->market->name eq 'forex' or $self->underlying->market->name eq 'commodities')) {
        $result->{underlying} = create_underlying({
            symbol   => 'frx' . $self->underlying->asset_symbol . $self->currency,
            for_date => $self->underlying->for_date
        });

        $result->{volsurface} = $self->_volsurface_fetcher->fetch_surface({
            underlying => $result->{underlying},
        });

    } else {
        $result = $self->domqqq;
    }

    return $result;
}

sub _build_fordom {
    my $self = shift;

    return {
        underlying => $self->underlying,
        volsurface => $self->volsurface,
    };
}

sub _build_discount_rate {
    my $self = shift;

    my %args = (
        symbol => $self->currency,
        $self->underlying->for_date ? (for_date => $self->underlying->for_date) : (),
        chronicle_reader => BOM::System::Chronicle::get_chronicle_reader($self->underlying->for_date),
        chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
    );
    my $curr_obj = Quant::Framework::Currency->new(%args);

    return $curr_obj->rate_for($self->timeinyears->amount);
}

=head2 get_time_to_expiry

Returns a TimeInterval to expiry of the bet. For a forward start bet, it will NOT return the bet lifetime, but the time till the bet expires,
if you want to get the bet life time call it like C<$bet-E<gt>get_time_to_expiry({from =E<gt> $bet-E<gt>date_start})>.

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

# PRIVATE METHOD: _get_time_to_end
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

has exit_tick => (
    is         => 'ro',
    lazy_build => 1,
);

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
            $self->add_error({
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

has primary_validation_error => (
    is       => 'rw',
    init_arg => undef,
);

sub add_error {
    my ($self, $err) = @_;
    $err->{set_by} = __PACKAGE__;
    $self->primary_validation_error(MooseX::Role::Validatable::Error->new(%$err));
    return;
}

has is_sold => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0
);

has [qw(risk_profile)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_risk_profile {
    my $self = shift;

    return BOM::Product::RiskProfile->new(
        underlying        => $self->underlying,
        contract_category => $self->category_code,
        expiry_type       => $self->expiry_type,
        start_type        => $self->start_type,
        currency          => $self->currency,
        barrier_category  => $self->barrier_category,
    );
}

has market_is_inefficient => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_market_is_inefficient {
    my $self = shift;

    # market inefficiency only applies to forex and commodities.
    return 0 unless ($self->market->name eq 'forex' or $self->market->name eq 'commodities');
    return 0 if $self->expiry_daily;

    my $hour = $self->date_pricing->hour + 0;
    # only 20:00/21:00 GMT to end of day
    my $disable_hour = $self->date_pricing->is_dst_in_zone('America/New_York') ? 20 : 21;
    return 0 if $hour < $disable_hour;
    return 1;
}

# Don't mind me, I just need to make sure my attibutes are available.
with 'BOM::Product::Role::Reportable';

no Moose;

__PACKAGE__->meta->make_immutable;

1;
