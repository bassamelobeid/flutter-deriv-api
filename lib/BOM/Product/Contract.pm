package BOM::Product::Contract;

use Moose;

# very bad name, not sure why it needs to be
# attached to Validatable.
use MooseX::Role::Validatable::Error;
use Math::Function::Interpolator;
use Quant::Framework::Currency;
use BOM::Product::Contract::Category;
use Time::HiRes qw(time);
use List::Util qw(min max first);
use List::MoreUtils qw(none all);
use Scalar::Util qw(looks_like_number);
use BOM::Product::RiskProfile;

use BOM::Market::UnderlyingDB;
use Math::Util::CalculatedValue::Validatable;
use Date::Utility;
use BOM::Market::Underlying;
use Quant::Framework::Spot::Tick;
use Quant::Framework::CorrelationMatrix;
use Format::Util::Numbers qw(to_monetary_number_format roundnear);
use Time::Duration::Concise;
use BOM::Product::Types;
use Quant::Framework::VolSurface::Utils;
use BOM::Platform::Context qw(request localize);
use BOM::MarketData::VolSurface::Empirical;
use BOM::MarketData::Fetcher::VolSurface;
use Quant::Framework::EconomicEventCalendar;
use BOM::Product::Offerings qw( get_contract_specifics get_offerings_flyby);
use BOM::System::Chronicle;

# require Pricing:: modules to avoid circular dependency problems.
require BOM::Product::Pricing::Engine::Intraday::Forex;
require BOM::Product::Pricing::Engine::Intraday::Index;
require BOM::Product::Pricing::Engine::VannaVolga::Calibrated;
require Pricing::Engine::EuropeanDigitalSlope;
require Pricing::Engine::TickExpiry;
require BOM::Product::Pricing::Greeks::BlackScholes;

sub is_spread { return 0 }
sub is_legacy { return 0 }

has [qw(id pricing_code display_name sentiment other_side_code payout_type payouttime)] => (
    is      => 'ro',
    default => undef,
);

has [qw(long_term_prediction)] => (
    is      => 'rw',
    default => undef,
);

has is_expired => (
    is         => 'ro',
    lazy_build => 1,
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
    isa        => 'bom_date_object',
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
    isa      => 'bom_date_object',
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
    isa        => 'Quant::Framework::Spot::Tick',
    lazy_build => 1,
);

sub _build_basis_tick {
    my $self = shift;

    my ($basis_tick, $potential_error);

    if (not $self->pricing_new and not $self->is_forward_starting) {
        $basis_tick      = $self->entry_tick;
        $potential_error = localize('Waiting for entry tick.');
    } else {
        $basis_tick      = $self->current_tick;
        $potential_error = localize('Trading on this market is suspended due to missing market data.');
    }

    # if there's no basis tick, don't die but catch the error.
    unless ($basis_tick) {
        $basis_tick = Quant::Framework::Spot::Tick->new({
            # slope pricer will die with illegal division by zero error when we get the slope
            quote  => $self->underlying->pip_size * 2,
            epoch  => 1,
            symbol => $self->underlying->symbol,
        });
        $self->add_error({
            message           => "Waiting for entry tick [symbol: " . $self->underlying->symbol . "]",
            message_to_client => $potential_error,
        });
    }

    return $basis_tick;
}

has starts_as_forward_starting => (
    is      => 'ro',
    default => 0,
);

#expiry_daily - Does this bet expire at close of the exchange?
has [qw( is_atm_bet expiry_daily is_intraday expiry_type start_type payouttime_code translated_display_name is_forward_starting permitted_expiries)]
    => (
    is         => 'ro',
    lazy_build => 1,
    );

sub _build_is_atm_bet {
    my $self = shift;

    # If more euro_atm options are added, use something like Offerings to replace static 'callput'
    return ($self->category->code eq 'callput' and defined $self->barrier and $self->barrier->pip_difference == 0) ? 1 : 0;
}

sub _build_expiry_daily {
    my $self = shift;
    return $self->is_intraday ? 0 : 1;
}

sub _build_is_intraday {
    my $self              = shift;
    my $contract_duration = $self->date_expiry->epoch - $self->effective_start->epoch;
    return ($contract_duration <= 86400) ? 1 : 0;
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
    isa     => 'bom_time_interval',
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
        bs_probability
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
    isa     => 'bom_underlying_object',
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

    if ($self->tick_expiry) {
        my @symbols = BOM::Market::UnderlyingDB->instance->get_symbols_for(
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
        my @symbols = BOM::Market::UnderlyingDB->instance->$func;
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

=item pricing_engine_parameters

Extra parameters to be sent to the pricing engine.  This can be very dangerous or incorrect if you
don't know what you are doing or why.  Use with caution.

=cut

has pricing_engine_parameters => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { return {}; },
);

sub _build_pricing_engine {
    my $self = shift;

    my $pricing_engine;
    if ($self->new_interface_engine) {
        my %pricing_parameters = map { $_ => $self->_pricing_parameters->{$_} } @{$self->pricing_engine_name->required_args};
        $pricing_engine = $self->pricing_engine_name->new(%pricing_parameters);
    } else {
        $pricing_engine = $self->pricing_engine_name->new({
                bet => $self,
                %{$self->pricing_engine_parameters}});
    }

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
    } elsif ($self->pricing_engine_name eq 'BOM::Product::Pricing::Engine::Asian' and $underlying->market->name eq 'volidx') {
        $rate = $q_rate / 2;
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

    # Forward starting contract bought. Not a new contract.
    return 0 if $self->starts_as_forward_starting;
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

    my $start_date = $self->effective_start;

    my $atid;
    # If market is Forex, We go with integer days as per the market convention
    if ($self->market->integer_number_of_day and not $self->priced_with_intraday_model) {
        my $recorded_date = $self->volsurface->recorded_date;
        my $utils         = Quant::Framework::VolSurface::Utils->new;
        my $days_between  = $self->date_expiry->days_between($recorded_date);
        $atid = $utils->is_before_rollover($recorded_date) ? ($days_between + 1) : $days_between;
        if ($recorded_date->day_of_week >= 5 or ($recorded_date->day_of_week == 4 and not $utils->is_before_rollover($recorded_date))) {
            $atid -= 1;
        }
        # On contract starting on Thursday expiring on Friday,
        # this algorithm will be zero. We are flooring it at 1 day.
        $atid = max(1, $atid);
    }
    # If intraday or not FX, then use the exact duration with fractions of a day.
    $atid ||= $self->get_time_to_expiry({
            from => $start_date,
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

    my @opposite_contract_parameters = qw(volsurface fordom forqqq domqqq);
    if ($self->pricing_new) {
        # setup the parameters for an opposite contract.
        $opp_parameters{date_start}  = $self->date_start;
        $opp_parameters{pricing_new} = 1;
        push @opposite_contract_parameters, qw(pricing_engine_name pricing_spot r_rate q_rate pricing_vol discount_rate mu barriers_for_pricing);
        push @opposite_contract_parameters, qw(empirical_volsurface long_term_prediction news_adjusted_pricing_vol)
            if $self->priced_with_intraday_model;
    } else {
        # not pricing_new will only happen when we are repricing an
        # existing contract in our system.

        # we still want to set for_sale for a forward_starting contracts
        $opp_parameters{for_sale} = 1;
        # delete traces of this contract were a forward starting contract before.
        delete $opp_parameters{starts_as_forward_starting};
        # duration could be set for an opposite contract from bad hash reference reused.
        delete $opp_parameters{duration};

        if (not $self->is_forward_starting) {
            if ($self->entry_tick) {
                foreach my $barrier ($self->two_barriers ? ('high_barrier', 'low_barrier') : ('barrier')) {
                    $opp_parameters{$barrier} = $self->$barrier->as_absolute if defined $self->$barrier;
                }
            }
            # We should be looking to move forward in time to a bet starting now.
            $opp_parameters{date_start}  = $self->date_pricing;
            $opp_parameters{pricing_new} = 1;
            # This should be removed in our callput ATM and non ATM minimum allowed duration is identical.
            # Currently, 'sell at market' button will appear when current spot == barrier when the duration
            # of the contract is less than the minimum duration of non ATM contract.
            $opp_parameters{is_atm_bet} = 0 if ($self->category_code eq 'callput');
        }
    }

    # Always switch out the bet type for the other side.
    $opp_parameters{'bet_type'} = $self->other_side_code;
    # Don't set the shortcode, as it will change between these.
    delete $opp_parameters{'shortcode'};
    # Save a round trip.. copy market data
    foreach my $vol_param (@opposite_contract_parameters) {
        $opp_parameters{$vol_param} = $self->$vol_param;
    }

    return $self->_produce_contract_ref->(\%opp_parameters);
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

sub _build_longcode {
    my $self = shift;

    # When we are building the longcode, we should always take the date_start to date_expiry as duration.
    # Don't use $self->expiry_type because that's use to price a contract at effective_start time.
    my $contract_duration = $self->date_expiry->epoch - $self->date_start->epoch;
    my $expiry_type = $self->tick_expiry ? 'tick' : $contract_duration > 86400 ? 'daily' : 'intraday';
    $expiry_type .= '_fixed_expiry' if $expiry_type eq 'intraday' and not $self->starts_as_forward_starting and $self->fixed_expiry;
    my $localizable_description = $self->localizable_description->{$expiry_type};

    my ($when_end, $when_start);
    if ($expiry_type eq 'intraday_fixed_expiry') {
        $when_end   = $self->date_expiry->datetime . ' GMT';
        $when_start = '';
    } elsif ($expiry_type eq 'intraday') {
        $when_end = $self->get_time_to_expiry({from => $self->date_start})->as_string;
        $when_start = $self->starts_as_forward_starting ? $self->date_start->db_timestamp . ' GMT' : localize('contract start time');
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
        ($self->currency, $payout, $self->underlying->translated_display_name, $when_start, $when_end, @barriers));
}

=item is_after_expiry

We have two types of expiries:
- Contracts can expire when a certain number of ticks is received.
- Contracts can expire when current time has past a pre-determined expiry time.

=back

=cut

sub is_after_expiry {
    my $self = shift;

    if ($self->tick_expiry) {
        return 1
            if ($self->exit_tick || ($self->date_pricing->epoch - $self->date_start->epoch > $self->max_tick_expiry_duration->seconds));
    } else {
        return 1 if $self->get_time_to_settlement->seconds == 0;
    }

    return;
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

    my $discount = Math::Util::CalculatedValue::Validatable->new({
        name        => 'discounted_probability',
        description => 'The discounted probability for both sides of this contract.  Time value.',
        set_by      => 'BOM::Product::Contract discount_rate and bet duration',
        minimum     => 0,
        maximum     => 1,
    });

    my $quanto = Math::Util::CalculatedValue::Validatable->new({
        name        => 'discount_rate',
        description => 'The rate for the payoff currency',
        set_by      => 'BOM::Product::Contract',
        base_amount => $self->discount_rate,
    });
    my $discount_rate = Math::Util::CalculatedValue::Validatable->new({
        name        => 'discount_rate',
        description => 'Full rate to use for discounting.',
        set_by      => 'BOM::Product::Contract',
        base_amount => -1,
    });

    $discount_rate->include_adjustment('multiply', $quanto);
    $discount_rate->include_adjustment('multiply', $self->timeinyears);

    $discount->include_adjustment('exp', $discount_rate);

    return $discount;
}

sub _build_bid_probability {
    my $self = shift;

    return $self->default_probabilities->{bid_probability} if $self->primary_validation_error;

    # Effectively you get the same price as if you bought the other side to cancel.
    my $marked_down = Math::Util::CalculatedValue::Validatable->new({
        name        => 'bid_probability',
        description => 'The price we would pay for this contract.',
        set_by      => 'BOM::Product::Contract',
        minimum     => 0,
        maximum     => $self->theo_probability->amount,
    });

    $marked_down->include_adjustment('add', $self->discounted_probability);
    $self->opposite_contract->ask_probability->exclude_adjustment('deep_otm_markup');
    $marked_down->include_adjustment('subtract', $self->opposite_contract->ask_probability);

    return $marked_down;
}

sub _build_bid_price {
    my $self = shift;

    return $self->_price_from_prob('bid_probability');
}

sub _build_ask_probability {
    my $self = shift;

    my $theo_probability = $self->theo_probability;
    my $min_ask          = $self->market->deep_otm_threshold;
    my $ask_cv           = Math::Util::CalculatedValue::Validatable->new({
        name        => 'ask_probability',
        description => 'The price we request for this contract.',
        set_by      => 'BOM::Product::Contract',
        minimum     => max($min_ask, $theo_probability->amount),
        maximum     => 1,
    });

    $ask_cv->include_adjustment('reset', $self->theo_probability);
    $ask_cv->include_adjustment('add',   $self->commission_markup);

    my $max_ask = 1 - $min_ask;
    if ($ask_cv->amount > $max_ask) {
        $ask_cv->include_adjustment('reset', $self->default_probabilities->{ask_probability});
    }

    return $ask_cv;
}

sub is_valid_to_buy {
    my $self = shift;

    my $valid = $self->confirm_validity;

    return ($self->for_sale) ? $valid : $self->_report_validation_stats('buy', $valid);
}

sub is_valid_to_sell {
    my $self = shift;

    if ($self->is_sold) {
        $self->add_error({
            message           => 'Contract already sold',
            message_to_client => localize("This contract has been sold."),
        });
        return 0;
    }

    if ($self->is_after_expiry) {
        if (my ($ref, $hold_for_exit_tick) = $self->_validate_settlement_conditions) {
            $self->missing_market_data(1) if not $hold_for_exit_tick;
            $self->add_error($ref);
        }
    } elsif (not $self->is_expired and not $self->opposite_contract->is_valid_to_buy) {
        # Their errors are our errors, now!
        $self->add_error($self->opposite_contract->primary_validation_error);
    }

    if (scalar @{$self->corporate_actions}) {
        $self->add_error({
            message           => "affected by corporate action [symbol: " . $self->underlying->symbol . "]",
            message_to_client => localize("This contract is affected by corporate action."),
        });
    }

    my $passes_validation = $self->primary_validation_error ? 0 : 1;
    return $self->_report_validation_stats('sell', $passes_validation);
}

# PRIVATE method.
sub _validate_settlement_conditions {
    my $self = shift;

    my $message;
    my $hold_for_exit_tick = 0;
    if ($self->tick_expiry) {
        if (not $self->exit_tick) {
            $message = 'exit tick undefined after 5 minutes of contract start';
        } elsif ($self->exit_tick->epoch - $self->date_start->epoch > $self->max_tick_expiry_duration->seconds) {
            $message = 'no ticks within 5 minutes after contract start';
        }
    } else {
        # intraday or daily expiry
        if (not $self->entry_tick) {
            $message = 'entry tick is undefined';
        } elsif ($self->is_forward_starting
            and ($self->date_start->epoch - $self->entry_tick->epoch > $self->underlying->max_suspend_trading_feed_delay->seconds))
        {
            # A start now contract will not be bought if we have missing feed.
            # We are doing the same thing for forward starting contracts.
            $message = 'entry tick is too old';
        } elsif (not $self->exit_tick) {
            $message            = 'exit tick is undefined';
            $hold_for_exit_tick = 1;
        } elsif ($self->entry_tick->epoch == $self->exit_tick->epoch) {
            $message = 'only one tick throughout contract period';
        } elsif ($self->entry_tick->epoch > $self->exit_tick->epoch) {
            $message = 'entry tick is after exit tick';
        }
    }

    return if not $message;

    my $refund = 'The buy price of this contract will be refunded due to missing market data.';
    my $wait   = 'Please wait for contract settlement.';

    my $ref = {
        message           => $message,
        message_to_client => ($hold_for_exit_tick ? $wait : $refund),
    };

    return ($ref, $hold_for_exit_tick);
}

#  If your price is payout * some probability, just use this.
sub _price_from_prob {
    my ($self, $prob_method) = @_;
    my $price;
    if ($self->date_pricing->is_after($self->date_start) and $self->is_expired) {
        $price = $self->value;
    } else {
        $price = (defined $self->$prob_method) ? $self->payout * $self->$prob_method->amount : undef;
    }
    return (defined $price) ? roundnear(($self->{currency} eq 'JPY' ? 1 : 0.01), $price) : undef;
}

sub _build_ask_price {
    my $self = shift;

    return $self->_price_from_prob('ask_probability');
}

sub _build_payout {
    my $self = shift;

    my $payout = max($self->ask_price, $self->_calculate_payout($self->commission_from_stake));
    return roundnear(($self->{currency} eq 'JPY' ? 1 : 0.01), $payout);
}

sub _calculate_payout {
    my ($self, $base_commission) = @_;

    # This is an approximation way of getting ask_prob to solve the issue where min ask price does not apply with predefined ask price.
    # If the issue still persists, a better quaratic solution is required.
    my $approximate_ask_prob = $self->theo_probability->amount + $base_commission;
    my $min_ask_prob         = $self->market->deep_otm_threshold;

    my $payout = ($approximate_ask_prob > $min_ask_prob) ? ($self->ask_price / $approximate_ask_prob) : ($self->ask_price / $min_ask_prob);
    return $payout;
}

my $commission_base_multiplier = 1;
my $commission_max_multiplier  = 2;
my $commission_min_std         = 500;
my $commission_max_std         = 25000;
my $commission_slope           = ($commission_max_multiplier - $commission_base_multiplier) / ($commission_max_std - $commission_min_std);

sub commission_multiplier {
    my ($self, $payout) = @_;

    my $theo_probability = $self->theo_probability->amount;
    my $std = $payout * sqrt($theo_probability * (1 - $theo_probability));

    return $commission_base_multiplier if $std <= $commission_min_std;
    return $commission_max_multiplier  if $std >= $commission_max_std;

    my $slope      = $commission_slope;
    my $multiplier = ($std - $commission_min_std) * $slope + 1;

    return $multiplier;
}

has commission_from_stake => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_commission_from_stake {
    my $self = shift;

    my $theo_probability    = $self->theo_probability->amount;
    my $ask_price           = $self->ask_price;
    my $base_commission     = $self->base_commission;
    my $app_commission      = $self->app_markup->amount;
    my $combined_commission = $base_commission + $app_commission;

    # payout calculated with base commission.
    my $initial_payout = $self->_calculate_payout($combined_commission);
    if ($self->commission_multiplier($initial_payout) == $commission_base_multiplier) {
        # a minimum of 2 cents please, payout could be zero.
        my $minimum_commission = $initial_payout ? 0.02 / $initial_payout : 0.02;
        return max($minimum_commission, $combined_commission);
    }

    # payout calculated with 2 times base commission.
    $combined_commission = $base_commission * 2 + $app_commission;
    $initial_payout      = $self->_calculate_payout($combined_commission);
    if ($self->commission_multiplier($initial_payout) == $commission_max_multiplier) {
        return $combined_commission;
    }

    my $a = $base_commission * $commission_slope * sqrt($theo_probability * (1 - $theo_probability));
    my $b = ($theo_probability + $base_commission - $base_commission * $commission_min_std * $commission_slope) + $app_commission;
    my $c = -$ask_price;

    # sets it to zero first.
    $initial_payout = 0;
    # We solve for payout as a quadratic function.
    for my $w (1, -1) {
        my $estimated_payout = (-$b + $w * sqrt($b**2 - 4 * $a * $c)) / (2 * $a);
        if ($estimated_payout > 0) {
            $initial_payout = $estimated_payout;
            last;
        }
    }

    # die if we could not get a positive payout value.
    die 'Could not calculate a payout' unless $initial_payout;

    return $base_commission * $self->commission_multiplier($initial_payout) + $app_commission;
}

sub _build_theo_probability {
    my $self = shift;

    if ($self->new_interface_engine) {
        return Math::Util::CalculatedValue::Validatable->new({
            name        => 'theo_probability',
            description => 'theorectical value of a contract',
            set_by      => $self->pricing_engine_name,
            base_amount => $self->pricing_engine->probability,
            minimum     => 0,
            maximum     => 1,
        });
    }

    return $self->pricing_engine->probability;
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
    my $self = shift;

    # app_markup_percentage could potentially be undef.
    my $app_markup_percentage = $self->app_markup_percentage // 0;

    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'app_markup',
        description => 'commission markup for app developer',
        set_by      => __PACKAGE__,
        base_amount => $app_markup_percentage / 100,
    });
}

sub _build_app_markup_dollar_amount {
    my $self = shift;

    return roundnear(0.01, $self->app_markup->amount * $self->payout);
}

sub _build_bs_probability {
    my $self = shift;

    my $bs_prob;
    # Have to keep it this way until we remove CalculatedValue in Contract.
    if ($self->new_interface_engine) {
        $bs_prob = Math::Util::CalculatedValue::Validatable->new({
            name        => 'bs_probability',
            description => 'BlackScholes value of a contract',
            set_by      => $self->pricing_engine_name,
            base_amount => $self->pricing_engine->bs_probability,
        });
    } else {
        $bs_prob = $self->pricing_engine->bs_probability;
    }

    return $bs_prob;
}

sub _build_bs_price {
    my $self = shift;

    return $self->_price_from_prob('bs_probability');
}

# base_commission can be overridden on contract type level.
# When this happens, underlying base_commission is ignored.
has [qw(risk_markup commission_markup base_commission)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_risk_markup {
    my $self = shift;

    my $base_amount = 0;
    if ($self->pricing_engine->can('risk_markup')) {
        $base_amount = $self->new_interface_engine ? $self->pricing_engine->risk_markup : $self->pricing_engine->risk_markup->amount;
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

    my $minimum        = BOM::System::Config::quants->{commission}->{adjustment}->{minimum} / 100;
    my $maximum        = BOM::System::Config::quants->{commission}->{adjustment}->{maximum} / 100;
    my $scaling_factor = BOM::Platform::Runtime->instance->app_config->quants->commission->adjustment->global_scaling / 100;
    $scaling_factor = max($minimum, min($maximum, $scaling_factor));

    return $self->underlying->base_commission * $scaling_factor;
}

sub _build_commission_markup {
    my $self = shift;

    my $base_amount   = $self->base_commission * $self->commission_multiplier($self->payout);
    my %min           = ($self->has_payout and $self->payout != 0) ? (minimum => 0.02 / $self->payout) : ();
    my $commission_cv = Math::Util::CalculatedValue::Validatable->new({
        name        => 'commission_markup',
        description => 'Commission markup for a pricing model',
        set_by      => __PACKAGE__,
        base_amount => $base_amount,
        maximum     => BOM::System::Config::quants->{commission}->{maximum_total_markup} / 100,
        %min,
    });

    $commission_cv->include_adjustment('add', $self->app_markup);

    return $commission_cv;
}

sub _build_theo_price {
    my $self = shift;

    return $self->_price_from_prob('theo_probability');
}

sub _build_shortcode {
    my $self = shift;

    my $shortcode_date_start = $self->is_forward_starting ? $self->date_start->epoch . 'F' : $self->date_start->epoch;
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
        $args->{long_term_prediction} = $self->long_term_prediction;
        $args->{iv_with_news}         = $self->news_adjusted_pricing_vol;
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
    my $pen = $self->pricing_engine_name;
    if ($pen =~ /VannaVolga/) {
        $vol = $self->volsurface->get_volatility({
            days  => $self->timeindays->amount,
            delta => 50
        });
    } elsif ($self->priced_with_intraday_model) {
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
        $self->long_term_prediction($volsurface->long_term_prediction);
        if ($volsurface->error) {
            $self->add_error({
                message => 'Too few periods for historical vol calculation '
                    . "[symbol: "
                    . $self->underlying->symbol . "] "
                    . "[duration: "
                    . $self->remaining_time->as_concise_string . "]",
                message_to_client => localize('Trading on this market is suspended due to missing market data.'),
            });
        }
    } else {
        $vol = $self->vol_at_strike;
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

    return [grep { $_->{release_date} >= $start and $_->{release_date} <= $end } @$all_events];
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

    my $pricing_spot = $self->pricing_spot;
    my $vol_args     = {
        strike => $self->barriers_for_pricing->{barrier1},
        q_rate => $self->q_rate,
        r_rate => $self->r_rate,
        spot   => $pricing_spot,
        days   => $self->timeindays->amount,
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
    my ($self) = @_;

    my $filter = {
        underlying_symbol => $self->underlying->symbol,
        contract_category => $self->category->code,
        expiry_type       => $self->expiry_type,
        start_type        => $self->start_type,
        barrier_category  => $self->barrier_category,
    };

    return get_contract_specifics($filter);
}

sub _build_barrier_category {
    my $self = shift;

    my $barrier_category;
    if ($self->category->code eq 'callput') {
        $barrier_category = ($self->is_atm_bet) ? 'euro_atm' : 'euro_non_atm';
    } else {
        $barrier_category = $BOM::Product::Offerings::BARRIER_CATEGORIES->{$self->category->code}->[0];
    }

    return $barrier_category;
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

    my $static                    = BOM::System::Config::quants;
    my $bet_limits                = $static->{bet_limits};
    my $per_contract_payout_limit = $static->{risk_profile}{$self->risk_profile->get_risk_profile}{payout}{$self->currency};
    my @possible_payout_maxes     = ($bet_limits->{maximum_payout}->{$curr}, $per_contract_payout_limit);

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
        'Pricing::Engine::TickExpiry'           => 1,
        'Pricing::Engine::EuropeanDigitalSlope' => 1,
    );

    return $engines{$self->pricing_engine_name} // 0;
}

sub _pricing_parameters {
    my $self = shift;

    return {
        priced_with       => $self->priced_with,
        spot              => $self->pricing_spot,
        strikes           => [grep { $_ } values %{$self->barriers_for_pricing}],
        date_start        => $self->effective_start,
        date_expiry       => $self->date_expiry,
        date_pricing      => $self->date_pricing,
        discount_rate     => $self->discount_rate,
        q_rate            => $self->q_rate,
        r_rate            => $self->r_rate,
        mu                => $self->mu,
        vol               => $self->pricing_vol,
        payouttime_code   => $self->payouttime_code,
        contract_type     => $self->pricing_code,
        underlying_symbol => $self->underlying->symbol,
        market_data       => $self->_market_data,
        market_convention => $self->_market_convention,
    };
}

sub _market_convention {
    my $self = shift;

    return {
        calculate_expiry => sub {
            my ($start, $expiry) = @_;
            my $utils = Quant::Framework::VolSurface::Utils->new;
            return $utils->effective_date_for($expiry)->days_between($utils->effective_date_for($start));
        },
        get_rollover_time => sub {
            my $when = shift;
            return Quant::Framework::VolSurface::Utils->new->NY1700_rollover_date_on($when);
        },
    };
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
                my $new_volsurface_obj = $volsurface->clone({surface => $surface_data});
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
            my $underlying = $underlyings{$args->{underlying_symbol}} // BOM::Market::Underlying->new({
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
            $args->{underlying} = $underlyings{$underlying_symbol} // BOM::Market::Underlying->new({
                symbol   => $underlying_symbol,
                for_date => $for_date
            });
            return BOM::Market::AggTicks->new->retrieve($args);
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
        my $correlation_u   = BOM::Market::Underlying->new($index);

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
        delta     => 50,
        days      => $self->$days_attr->amount,
        for_epoch => $self->effective_start->epoch,
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
        $result->{underlying} = BOM::Market::Underlying->new({
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
        $result->{underlying} = BOM::Market::Underlying->new({
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

    return $self->_get_time_to_end($attributes);
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
    } elsif ($self->expiry_daily) {
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

# Validation methods.

# Is this underlying or contract is disabled/suspended from trading.
sub _validate_offerings {
    my $self = shift;

    my $message_to_client = localize('This trade is temporarily unavailable.');

    if (BOM::Platform::Runtime->instance->app_config->system->suspend->trading) {
        return {
            message           => 'All trading suspended on system',
            message_to_client => $message_to_client,
        };
    }

    my $underlying      = $self->underlying;
    my $translated_name = $underlying->translated_display_name();

    if ($underlying->is_trading_suspended) {
        return {
            message           => "Underlying trades suspended [symbol: " . $underlying->symbol . "]",
            message_to_client => $message_to_client,
        };
    }

    my $contract_code = $self->code;
    # check if trades are suspended on that claimtype
    my $suspend_claim_types = BOM::Platform::Runtime->instance->app_config->quants->features->suspend_claim_types;
    if (@$suspend_claim_types and first { $contract_code eq $_ } @{$suspend_claim_types}) {
        return {
            message           => "Trading suspended for contract type [code: " . $contract_code . "]",
            message_to_client => $message_to_client,
        };
    }

    if (first { $_ eq $underlying->symbol } @{BOM::Platform::Runtime->instance->app_config->quants->underlyings->disabled_due_to_corporate_actions}) {
        return {
            message           => "Underlying trades suspended due to corporate actions [symbol: " . $underlying->symbol . "]",
            message_to_client => $message_to_client,
        };
    }

    if ($self->risk_profile->get_risk_profile eq 'no_business') {
        return {
            message           => 'manually disabled by quants',
            message_to_client => $message_to_client,
        };
    }

    return;
}

sub _validate_feed {
    my $self = shift;

    return if $self->is_expired;

    my $underlying      = $self->underlying;
    my $translated_name = $underlying->translated_display_name();

    if (not $self->current_tick) {
        return {
            message           => "No realtime data [symbol: " . $underlying->symbol . "]",
            message_to_client => localize('Trading on this market is suspended due to missing market data.'),
        };
    } elsif ($self->calendar->is_open_at($self->date_pricing)
        and $self->date_pricing->epoch - $underlying->max_suspend_trading_feed_delay->seconds > $self->current_tick->epoch)
    {
        # only throw errors for quote too old, if the exchange is open at pricing time
        return {
            message           => "Quote too old [symbol: " . $underlying->symbol . "]",
            message_to_client => localize('Trading on this market is suspended due to missing market data.'),
        };
    }

    return;
}

sub validate_price {
    my $self = shift;

    return if $self->for_sale;

    my $ask_price         = $self->ask_price;
    my $payout            = $self->payout;
    my $minimum_ask_price = $self->staking_limits->{min};
    my $maximum_payout    = $self->staking_limits->{max};

    if (not $ask_price) {
        return {
            message           => "Empty or zero stake [stake: " . $ask_price . "]",
            message_to_client => localize("Invalid stake"),
        };
    }

    my $message_to_client = localize(
        'Minimum stake of [_1] and maximum payout of [_2]',
        to_monetary_number_format($minimum_ask_price),
        to_monetary_number_format($maximum_payout));
    my $message_to_client_array = [
        'Minimum stake of [_1] and maximum payout of [_2]', to_monetary_number_format($minimum_ask_price),
        to_monetary_number_format($maximum_payout)];
    if ($ask_price < $minimum_ask_price) {
        return {
            message                 => 'stake is not within limits ' . "[stake: " . $ask_price . "] " . "[min: " . $minimum_ask_price . "] ",
            message_to_client       => $message_to_client,
            message_to_client_array => $message_to_client_array,
        };
    } elsif ($payout > $maximum_payout) {
        return {
            message                 => 'payout amount outside acceptable range ' . "[given: " . $payout . "] " . "[max: " . $maximum_payout . "]",
            message_to_client       => $message_to_client,
            message_to_client_array => $message_to_client_array,
        };
    }

    my $payout_as_string = "" . $payout;    #Just to be sure we're deailing with a string.
    $payout_as_string =~ s/[\.0]+$//;       # Strip trailing zeroes and decimal points to be more friendly.

    if ($payout =~ /\.[0-9]{3,}/) {
        # We did the best we could to clean up looks like still too many decimals
        return {
            message           => 'payout amount has too many decimal places ' . "[permitted: 2] " . "[payout: " . $payout . "]",
            message_to_client => localize('Payout may not have more than two decimal places.',),
        };
    }

    # Compared as strings of maximum visible client currency width to avoid floating-point issues.
    if (sprintf("%.2f", $ask_price) eq sprintf("%.2f", $payout)) {
        return {
            message           => 'stake same as payout',
            message_to_client => localize('This contract offers no return.'),
        };
    }

    return;
}

sub _validate_input_parameters {
    my $self = shift;

    my $when_epoch   = $self->date_pricing->epoch;
    my $epoch_expiry = $self->date_expiry->epoch;
    my $epoch_start  = $self->date_start->epoch;

    if ($epoch_expiry == $epoch_start) {
        return {
            message           => 'Start and Expiry times are the same ' . "[start: " . $epoch_start . "] " . "[expiry: " . $epoch_expiry . "]",
            message_to_client => localize('Expiry time cannot be equal to start time.'),
        };
    } elsif ($epoch_expiry < $epoch_start) {
        return {
            message           => 'Start must be before expiry ' . "[start: " . $epoch_start . "] " . "[expiry: " . $epoch_expiry . "]",
            message_to_client => localize("Expiry time cannot be in the past."),
        };
    } elsif (not $self->for_sale and $epoch_start < $when_epoch) {
        return {
            message           => 'starts in the past ' . "[start: " . $epoch_start . "] " . "[now: " . $when_epoch . "]",
            message_to_client => localize("Start time is in the past"),
        };
    } elsif (not $self->is_forward_starting and $epoch_start > $when_epoch) {
        return {
            message           => "Forward time for non-forward-starting contract type [code: " . $self->code . "]",
            message_to_client => localize('Start time is in the future.'),
        };
    } elsif ($self->is_forward_starting and not $self->for_sale) {
        # Intraday cannot be bought in the 5 mins before the bet starts, unless we've built it for that purpose.
        my $fs_blackout_seconds = 300;
        if ($epoch_start < $when_epoch + $fs_blackout_seconds) {
            return {
                message           => "forward-starting blackout [blackout: " . $fs_blackout_seconds . "s]",
                message_to_client => localize("Start time on forward-starting contracts must be more than 5 minutes from now."),
            };
        }
    } elsif ($self->is_after_expiry) {
        return {
            message           => 'already expired contract',
            message_to_client => localize("Contract has already expired."),
        };
    } elsif ($self->expiry_daily) {
        my $date_expiry = $self->date_expiry;
        my $closing     = $self->calendar->closing_on($date_expiry);
        if ($closing and not $date_expiry->is_same_as($closing)) {
            return {
                message => 'daily expiry must expire at close '
                    . "[expiry: "
                    . $date_expiry->datetime . "] "
                    . "[underlying_symbol: "
                    . $self->underlying->symbol . "]",
                message_to_client =>
                    localize('Contracts on this market with a duration of more than 24 hours must expire at the end of a trading day.'),
            };
        }
    }

    return;
}

sub _validate_trading_times {
    my $self = shift;

    my $underlying  = $self->underlying;
    my $calendar    = $underlying->calendar;
    my $date_expiry = $self->date_expiry;
    my $date_start  = $self->date_start;

    if (not($calendar->trades_on($date_start) and $calendar->is_open_at($date_start))) {
        my $message =
            ($self->is_forward_starting) ? localize("The market must be open at the start time.") : localize('This market is presently closed.');
        return {
            message => 'underlying is closed at start ' . "[symbol: " . $underlying->symbol . "] " . "[start: " . $date_start->datetime . "]",
            message_to_client => $message . " " . localize("Try out the Volatility Indices which are always open.")};
    } elsif (not $calendar->trades_on($date_expiry)) {
        return ({
            message           => "Exchange is closed on expiry date [expiry: " . $date_expiry->date . "]",
            message_to_client => localize("The contract must expire on a trading day."),
        });
    }

    if ($self->is_intraday) {
        if (not $calendar->is_open_at($date_expiry)) {
            return {
                message => 'underlying closed at expiry ' . "[symbol: " . $underlying->symbol . "] " . "[expiry: " . $date_expiry->datetime . "]",
                message_to_client => localize("Contract must expire during trading hours."),
            };
        } elsif ($underlying->intradays_must_be_same_day and $calendar->closing_on($date_start)->epoch < $date_expiry->epoch) {
            return {
                message           => "Intraday duration must expire on same day [symbol: " . $underlying->symbol . "]",
                message_to_client => localize('Contracts on this market with a duration of under 24 hours must expire on the same trading day.'),
            };
        }
    } elsif ($self->expiry_daily and not $self->is_atm_bet) {
        # For definite ATM contracts we do not have to check for upcoming holidays.
        my $trading_days = $self->calendar->trading_days_between($date_start, $date_expiry);
        my $holiday_days = $self->calendar->holiday_days_between($date_start, $date_expiry);
        my $calendar_days = $date_expiry->days_between($date_start);

        if ($underlying->market->equity and $trading_days <= 4 and $holiday_days >= 2) {
            my $safer_expiry = $date_expiry;
            my $trade_count  = $trading_days;
            while ($trade_count < 4) {
                $safer_expiry = $underlying->trade_date_after($safer_expiry);
                $trade_count++;
            }
            my $message =
                ($self->for_sale)
                ? localize('Resale of this contract is not offered due to market holidays during contract period.')
                : localize("Too many market holidays during the contract period.");
            return {
                message => 'Not enough trading days for calendar days ' . "[trading: " . $trading_days . "] " . "[calendar: " . $calendar_days . "]",
                message_to_client => $message,
            };
        }
    }

    return;
}

has date_start_blackouts => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_date_start_blackouts {
    my $self = shift;

    my @periods;
    my $underlying = $self->underlying;
    my $calendar   = $underlying->calendar;
    my $start      = $self->date_start;

    # We need to set sod_blackout_start for forex on Monday morning because otherwise, if there is no tick ,it will always take Friday's last tick and trigger the missing feed check
    if (my $sod = $calendar->opening_on($start)) {
        my $sod_blackout =
              ($underlying->sod_blackout_start) ? $underlying->sod_blackout_start
            : ($underlying->market->name eq 'forex' and $self->is_forward_starting and $start->day_of_week == 1) ? '10m'
            :                                                                                                      '';
        if ($sod_blackout) {
            push @periods, [$sod->epoch, $sod->plus_time_interval($sod_blackout)->epoch];
        }
    }

    my $end_of_trading = $calendar->closing_on($start);
    if ($end_of_trading) {
        if ($self->is_intraday) {
            my $eod_blackout =
                ($self->tick_expiry and ($underlying->resets_at_open or ($underlying->market->name eq 'forex' and $start->day_of_week == 5)))
                ? $self->max_tick_expiry_duration
                : $underlying->eod_blackout_start;
            push @periods, [$end_of_trading->minus_time_interval($eod_blackout)->epoch, $end_of_trading->epoch] if $eod_blackout;
        }

        if ($underlying->market->name eq 'indices' and not $self->is_intraday and not $self->is_atm_bet and $self->timeindays->amount <= 7) {
            push @periods, [$end_of_trading->minus_time_interval('1h')->epoch, $end_of_trading->epoch];
        }
    }

    # Due to uncertainty in volsurface rollover time, we will stay out.
    if ($self->market->name eq 'forex' and not $self->is_atm_bet and $self->timeindays->amount <= 3) {
        my $rollover_date = Quant::Framework::VolSurface::Utils->new->NY1700_rollover_date_on($self->date_start);
        push @periods, [$rollover_date->minus_time_interval('1h')->epoch, $rollover_date->plus_time_interval('1h')->epoch];
    }

    return \@periods;
}

has date_expiry_blackouts => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_date_expiry_blackouts {
    my $self = shift;

    my @periods;
    my $underlying = $self->underlying;
    my $date_start = $self->date_start;

    if ($self->is_intraday) {
        my $end_of_trading = $underlying->calendar->closing_on($self->date_start);
        if ($end_of_trading and my $expiry_blackout = $underlying->eod_blackout_expiry) {
            push @periods, [$end_of_trading->minus_time_interval($expiry_blackout)->epoch, $end_of_trading->epoch];
        }
    } elsif ($self->expiry_daily and $underlying->market->equity and not $self->is_atm_bet) {
        my $start_of_period = BOM::System::Config::quants->{bet_limits}->{holiday_blackout_start};
        my $end_of_period   = BOM::System::Config::quants->{bet_limits}->{holiday_blackout_end};
        if ($self->date_start->day_of_year >= $start_of_period or $self->date_start->day_of_year <= $end_of_period) {
            my $year = $self->date_start->day_of_year > $start_of_period ? $date_start->year : $date_start->year - 1;
            my $end_blackout = Date::Utility->new($year . '-12-31')->plus_time_interval($end_of_period . 'd23h59m59s');
            push @periods, [$self->date_start->epoch, $end_blackout->epoch];
        }
    }

    return \@periods;
}

=head2 market_risk_blackouts

Periods of which we decide to stay out of the market due to high uncertainty.

=cut

has market_risk_blackouts => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_market_risk_blackouts {
    my $self = shift;

    my @blackout_periods;
    my $effective_sod = $self->effective_start->truncate_to_day;
    my $underlying    = $self->underlying;

    if ($self->is_intraday) {
        if (my @inefficient_periods = @{$underlying->inefficient_periods}) {
            push @blackout_periods, [$effective_sod->plus_time_interval($_->{start})->epoch, $effective_sod->plus_time_interval($_->{end})->epoch]
                for @inefficient_periods;
        }

        if (not $self->is_atm_bet and $self->underlying->market->name eq 'forex') {
            push @blackout_periods, [$_->{blankout}, $_->{blankout_end}] for @{$self->tentative_events};
        }
    }

    return \@blackout_periods;
}

sub _validate_start_and_expiry_date {
    my $self = shift;

    my $start_epoch     = $self->effective_start->epoch;
    my $end_epoch       = $self->date_expiry->epoch;
    my @blackout_checks = (
        [[$start_epoch], $self->date_start_blackouts,  "Trading is not available from [_2] to [_3]"],
        [[$end_epoch],   $self->date_expiry_blackouts, "Contract may not expire between [_2] and [_3]"],
        [[$start_epoch, $end_epoch], $self->market_risk_blackouts, "Trading is not available from [_2] to [_3]"],
    );

    my @args = ($self->underlying->translated_display_name);

    foreach my $blackout (@blackout_checks) {
        my ($epochs, $periods, $message_to_client) = @{$blackout}[0 .. 2];
        foreach my $period (@$periods) {
            if (first { $_ >= $period->[0] and $_ < $period->[1] } @$epochs) {
                my $start = Date::Utility->new($period->[0]);
                my $end   = Date::Utility->new($period->[1]);
                if ($start->day_of_year == $end->day_of_year) {
                    push @args, ($start->time_hhmmss, $end->time_hhmmss);
                } else {
                    push @args, ($start->date, $end->date);
                }
                return {
                    message => 'blackout period '
                        . "[symbol: "
                        . $self->underlying->symbol . "] "
                        . "[from: "
                        . $period->[0] . "] " . "[to: "
                        . $period->[1] . "]",
                    message_to_client => localize($message_to_client, @args),
                };
            }
        }
    }

    return;
}

sub _validate_lifetime {
    my $self = shift;

    if ($self->tick_expiry and $self->for_sale) {
        # we don't offer sellback on tick expiry contracts.
        return {
            message           => 'resale of tick expiry contract',
            message_to_client => localize('Resale of this contract is not offered.'),
        };
    }

    my $permitted = $self->permitted_expiries;
    my ($min_duration, $max_duration) = @{$permitted}{'min', 'max'};

    my $message_to_client_array;
    my $message_to_client =
        $self->for_sale
        ? localize('Resale of this contract is not offered.')
        : localize('Trading is not offered for this duration.');

    # This might be empty because we don't have short-term expiries on some contracts, even though
    # it's a valid bet type for multi-day contracts.
    if (not($min_duration and $max_duration)) {
        return {
            message           => 'trying unauthorised combination',
            message_to_client => $message_to_client,
        };
    }

    my ($duration, $message);
    if ($self->tick_expiry) {
        $duration = $self->tick_count;
        $message  = 'Invalid tick count for tick expiry';
        # slightly different message for tick expiry.
        if ($min_duration != 0) {
            $message_to_client = localize('Number of ticks must be between [_1] and [_2]', $min_duration, $max_duration);
            $message_to_client_array = ['Number of ticks must be between [_1] and [_2]', $min_duration, $max_duration];
        }
    } elsif (not $self->expiry_daily) {
        $duration = $self->get_time_to_expiry({from => $self->date_start})->seconds;
        ($min_duration, $max_duration) = ($min_duration->seconds, $max_duration->seconds);
        $message = 'Intraday duration not acceptable';
    } else {
        my $calendar = $self->calendar;
        $duration = $calendar->trading_date_for($self->date_expiry)->days_between($calendar->trading_date_for($self->date_start));
        ($min_duration, $max_duration) = ($min_duration->days, $max_duration->days);
        $message = 'Daily duration is outside acceptable range';
    }

    if ($duration < $min_duration or $duration > $max_duration) {
        return {
            message => $message . " "
                . "[duration seconds: "
                . $duration . "] "
                . "[symbol: "
                . $self->underlying->symbol . "] "
                . "[code: "
                . $self->code . "]",
            message_to_client       => $message_to_client,
            message_to_client_array => $message_to_client_array,
        };
    }

    return;
}

sub _validate_volsurface {
    my $self = shift;

    my $volsurface        = $self->volsurface;
    my $now               = $self->date_pricing;
    my $message_to_client = localize('Trading is suspended due to missing market data.');
    my $surface_age       = ($now->epoch - $volsurface->recorded_date->epoch) / 3600;

    if ($volsurface->get_smile_flags) {
        return {
            message           => "Volsurface has smile flags [symbol: " . $self->underlying->symbol . "]",
            message_to_client => $message_to_client,
        };
    }

    my $exceeded;
    if (    $self->market->name eq 'forex'
        and not $self->priced_with_intraday_model
        and $self->timeindays->amount < 4
        and not $self->is_atm_bet
        and $surface_age > 6)
    {
        $exceeded = '6h';
    } elsif ($self->market->name eq 'indices' and $surface_age > 24 and not $self->is_atm_bet) {
        $exceeded = '24h';
    } elsif ($volsurface->recorded_date->days_between($self->calendar->trade_date_before($now)) < 0) {
        # will discuss if this can be removed.
        $exceeded = 'different day';
    }

    if ($exceeded) {
        return {
            message => 'volsurface too old '
                . "[symbol: "
                . $self->underlying->symbol . "] "
                . "[age: "
                . $surface_age . "h] "
                . "[max: "
                . $exceeded . "]",
            message_to_client => $message_to_client,
        };
    }

    if ($volsurface->type eq 'moneyness' and my $current_spot = $self->current_spot) {
        if (abs($volsurface->spot_reference - $current_spot) / $current_spot * 100 > 5) {
            return {
                message => 'spot too far from surface reference '
                    . "[symbol: "
                    . $self->underlying->symbol . "] "
                    . "[spot: "
                    . $current_spot . "] "
                    . "[surface reference: "
                    . $volsurface->spot_reference . "]",
                message_to_client => $message_to_client,
            };
        }
    }

    return;
}

has primary_validation_error => (
    is       => 'rw',
    init_arg => undef,
);

sub confirm_validity {
    my $self = shift;

    # if there's initialization error, we will not proceed anyway.
    return 0 if $self->primary_validation_error;

    # Add any new validation methods here.
    # Looking them up can be too slow for pricing speed constraints.
    # This is the default list of validations.
    my @validation_methods = qw(_validate_input_parameters _validate_offerings _validate_lifetime  _validate_barrier _validate_feed validate_price);

    push @validation_methods, '_validate_volsurface' if (not $self->volsurface->type eq 'flat');
    push @validation_methods, qw(_validate_trading_times _validate_start_and_expiry_date) if not $self->underlying->always_available;

    foreach my $method (@validation_methods) {
        if (my $err = $self->$method) {
            $self->add_error($err);
        }
        return 0 if ($self->primary_validation_error);
    }

    return 1;
}

sub add_error {
    my ($self, $err) = @_;
    $err->{set_by} = __PACKAGE__;
    $self->primary_validation_error(MooseX::Role::Validatable::Error->new(%$err));
    return;
}

has default_probabilities => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_default_probabilities {
    my $self = shift;

    my %probabilities = (
        ask_probability => {
            description => 'The price we request for this contract.',
            default     => 1,
        },
        bid_probability => {
            description => 'The price we would pay for this contract.',
            default     => 0,
        },
    );
    my %map = map {
        $_ => Math::Util::CalculatedValue::Validatable->new({
            name        => $_,
            description => $probabilities{$_}{description},
            set_by      => __PACKAGE__,
            base_amount => $probabilities{$_}{default},
        });
    } keys %probabilities;

    return \%map;
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

# Don't mind me, I just need to make sure my attibutes are available.
with 'BOM::Product::Role::Reportable';

no Moose;

__PACKAGE__->meta->make_immutable;

1;
