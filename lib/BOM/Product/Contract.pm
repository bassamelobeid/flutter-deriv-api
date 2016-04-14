package BOM::Product::Contract;

use Moose;
use Carp;

# very bad name, not sure why it needs to be
# attached to Validatable.
use MooseX::Role::Validatable::Error;
use BOM::Market::Currency;
use BOM::Product::Contract::Category;
use Time::HiRes qw(time sleep);
use List::Util qw(min max first);
use List::MoreUtils qw(none uniq);
use Scalar::Util qw(looks_like_number);

use BOM::Market::UnderlyingDB;
use Math::Util::CalculatedValue::Validatable;
use Date::Utility;
use BOM::Market::Underlying;
use BOM::Market::Data::Tick;
use BOM::MarketData::CorrelationMatrix;
use BOM::Market::Exchange;
use Format::Util::Numbers qw(to_monetary_number_format roundnear);
use Time::Duration::Concise::Localize;
use BOM::Product::Types;
use BOM::MarketData::VolSurface::Utils;
use BOM::Platform::Context qw(request localize);
use BOM::MarketData::VolSurface::Empirical;
use BOM::MarketData::Fetcher::VolSurface;
use Quant::Framework::EconomicEventCalendar;
use BOM::Product::Offerings qw( get_contract_specifics );
use BOM::Utility::ErrorStrings qw( format_error_string );
use BOM::MarketData::VolSurface::Utils;
use BOM::Platform::Static::Config;

# require Pricing:: modules to avoid circular dependency problems.
require BOM::Product::Pricing::Engine::Intraday::Forex;
require BOM::Product::Pricing::Engine::Intraday::Index;
require BOM::Product::Pricing::Engine::VannaVolga::Calibrated;
require Pricing::Engine::EuropeanDigitalSlope;
require Pricing::Engine::TickExpiry;

require BOM::Product::Pricing::Greeks::BlackScholes;

sub is_spread { return 0 }

has [qw(id pricing_code display_name sentiment other_side_code payout_type payouttime)] => (
    is      => 'ro',
    default => undef,
);

has [qw(average_tick_count long_term_prediction)] => (
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
    handles => [qw(supported_expiries supported_start_types is_path_dependent allow_forward_starting two_barriers)],
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
    isa        => 'BOM::Market::Data::Tick',
    lazy_build => 1,
);

sub _build_basis_tick {
    my $self = shift;

    # Getting basis tick can be tricky when we have feed outage or empty cache.
    # We will have to give our best guess sometimes.
    my $basis_tick =
          ($self->entry_tick)   ? $self->entry_tick
        : ($self->current_tick) ? $self->current_tick
        :                         $self->underlying->tick_at(Date::Utility->new->epoch, {allow_inconsistent => 1});

    # if there's no tick in our system, don't die
    unless ($basis_tick) {
        $basis_tick = BOM::Market::Data::Tick->new({
            quote  => $self->underlying->pip_size,
            epoch  => 1,
            symbol => $self->underlying->symbol,
        });
        $self->add_error({
            message => format_error_string('Could not retrieve a quote', symbol => $self->underlying->symbol),
            message_to_client => localize('Trading on [_1] is suspended due to missing market data.', $self->underlying->translated_display_name),
        });
    }

    return $basis_tick;
}

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

    my $underlying  = $self->underlying;
    my $expiry_type = $self->expiry_type;

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

has max_missing_ticks => (
    is      => 'ro',
    isa     => 'Int',
    default => 5,
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

=item built_with_bom_parameters

Was this bet built using BOM-generated parameters, as opposed to user-supplied parameters?

Be sure, as this allows us to relax some checks. Don't relax too much, as this still came from a
user at some point.. and they are wily.

This will contain the shortcode of the original bet, if we built it from one.

=cut

has built_with_bom_parameters => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
);

=item require_entry_tick_for_sale

A Boolean which expresses whether we can give a best effort guess or if we
need the correct price for sale. Defaults to false, should be set true for real
transactions.

=cut

has require_entry_tick_for_sale => (
    is      => 'ro',
    isa     => 'Bool',
    default => undef,
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

=item hold_for_entry_tick

A TimeInterval which expresses how long we should wait for an entry tick.  If set to 0, we can
proceed without getting the entry_tick.

=cut

has hold_for_entry_tick => (
    is         => 'ro',
    isa        => 'bom_time_interval',
    lazy_build => 1,
    coerce     => 1,
);

sub _build_hold_for_entry_tick {
    my $self = shift;

    return ($self->built_with_bom_parameters && $self->require_entry_tick_for_sale) ? '15s' : '0s';
}

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
    isa        => 'BOM::MarketData::VolSurface',
    lazy_build => 1,
);

# commission_adjustment - A multiplicative factor which adjusts the model_markup.  This scale factor must be in the range [0.01, 5].
# discounted_probability - The discounted total probability, given the time value of the money at stake.
# timeindays/timeinyears - note that for FX contracts of >=1 duration, these values will follow the market convention of integer days
has [qw(
        commission_adjustment
        model_markup
        total_markup
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

has exchange => (
    is      => 'ro',
    isa     => 'BOM::Market::Exchange',
    lazy    => 1,
    default => sub { return shift->underlying->exchange; },
);

has opposite_bet => (
    is         => 'ro',
    isa        => 'BOM::Product::Contract',
    lazy_build => 1
);

sub _build_date_settlement {
    my $self       = shift;
    my $end_date   = $self->date_expiry;
    my $underlying = $self->underlying;

    my $date_settlement = $end_date;    # Usually we settle when we expire.
    if ($self->expiry_daily) {
        if ($self->exchange->trades_on($end_date)) {
            $date_settlement = $self->exchange->settlement_on($end_date);
        } else {
            $self->add_error({
                message           => format_error_string('Exchange is closed on expiry date', expiry => $self->date_expiry->date),
                message_to_client => localize("The contract must expire on a trading day."),
            });
        }
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
        } qw(forex indices)
        )
    {
        my $func = $self->market->name eq 'forex' ? 'symbols_for_intraday_fx' : 'symbols_for_intraday_index';
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
    default => sub { return +{}; },
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
    } elsif ($self->pricing_engine_name eq 'BOM::Product::Pricing::Engine::Asian' and $underlying->market->name eq 'random') {
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

    return ($self->entry_tick) ? $self->entry_tick->quote : $self->current_spot;
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
    return ($time > $self->date_start->epoch) ? 0 : 1;
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
    if ($self->market->integer_number_of_day and $self->pricing_engine_name !~ /Intraday::Forex/) {
        my $utils        = BOM::MarketData::VolSurface::Utils->new;
        my $days_between = $self->date_expiry->days_between($self->date_start);
        $atid = $utils->is_before_rollover($self->date_start) ? ($days_between + 1) : $days_between;
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

sub _build_opposite_bet {
    my $self = shift;

    # Start by making a copy of the parameters we used to build this bet.
    my %build_parameters = %{$self->build_parameters};
    # Note from which extant bet we are building this.
    $build_parameters{'built_with_bom_parameters'} = 1;

    # Always switch out the bet type for the other side.
    $build_parameters{'bet_type'} = $self->other_side_code;
    # Don't set the shortcode, as it will change between these.
    delete $build_parameters{'shortcode'};
    # Save a round trip.. copy the volsurfaces
    foreach my $vol_param (qw(volsurface empirical_volsurface fordom forqqq domqqq)) {
        my $predicate = 'has_' . $vol_param;
        $build_parameters{$vol_param} = $self->$vol_param if ($self->$predicate);
    }

    # We should be looking to move forward in time to a bet starting now.
    if (not $self->pricing_new) {
        if ($self->entry_tick) {
            foreach my $barrier ($self->two_barriers ? ('high_barrier', 'low_barrier') : ('barrier')) {
                $build_parameters{$barrier} = $self->$barrier->as_absolute if defined $self->$barrier;
            }
        }
        $build_parameters{date_start}   = $self->date_pricing;
        $build_parameters{date_pricing} = $self->date_pricing;
    }

    # Secret hidden parameter for sell-time checking;
    $build_parameters{_original_date_start} = $self->date_start;

    return $self->_produce_contract_ref->(\%build_parameters);
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
    my $vol_utils = BOM::MarketData::VolSurface::Utils->new;
    my $cutoff_str;
    if ($submarkets{$self->underlying->submarket->name}) {
        my $exchange       = $self->exchange;
        my $effective_date = $vol_utils->effective_date_for($self->date_pricing);
        $effective_date = $exchange->trades_on($effective_date) ? $effective_date : $exchange->trade_date_after($effective_date);
        my $cutoff_date = $exchange->closing_on($effective_date);

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

    my $expiry_type = $self->expiry_type;
    $expiry_type .= '_fixed_expiry' if $expiry_type eq 'intraday' and not $self->is_forward_starting and $self->fixed_expiry;
    my $localizable_description = $self->localizable_description->{$expiry_type};

    my ($when_end, $when_start);
    if ($expiry_type eq 'intraday_fixed_expiry') {
        $when_end   = $self->date_expiry->datetime;
        $when_start = '';
    } elsif ($expiry_type eq 'intraday') {
        $when_end = $self->get_time_to_expiry({from => $self->date_start})->as_string;
        $when_start = $self->is_forward_starting ? $self->date_start->db_timestamp : localize('contract start time');
    } elsif ($expiry_type eq 'daily') {
        my $close = $self->underlying->exchange->closing_on($self->date_expiry);
        if ($close and $close->epoch != $self->date_expiry->epoch) {
            $when_end = $self->date_expiry->datetime;
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

    my $after_expiry = 0;

    if ($self->tick_expiry) {
        $after_expiry = 1
            if $self->date_pricing->epoch - $self->date_start->epoch > 3
            and $self->exit_tick;    # we consider tick expiry contracts to expire once we have exit tick
    } else {
        $after_expiry = 1 if !$self->get_time_to_settlement->seconds;
    }

    return $after_expiry;
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
        my $first_day_close = $underlying->exchange->closing_on($self->date_start);
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

    return $self->underlying->dividend_adjustments_for_period({
        start => $self->date_pricing,
        end   => $self->date_expiry,
    });
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
    $self->opposite_bet->ask_probability->exclude_adjustment('deep_otm_markup');
    $marked_down->include_adjustment('subtract', $self->opposite_bet->ask_probability);

    return $marked_down;
}

sub _build_bid_price {
    my $self = shift;

    return $self->_price_from_prob('bid_probability');
}

sub _build_total_markup {
    my $self = shift;

    my %max =
          ($self->pricing_engine_name =~ /Intraday::Forex/ and not $self->is_atm_bet)
        ? ()
        : (maximum => BOM::Platform::Static::Config::quants->{commission}->{maximum_total_markup} / 100);

    my %min;
    if ($self->pricing_engine_name =~ /TickExpiry/) {
        # we allowed tick expiry total markup to be less than zero
        # because of equal tick discount.
        %min = ();
    } elsif ($self->has_payout and $self->payout != 0) {
        %min = (minimum => 0.02 / $self->payout);
    } else {
        %min = (minimum => 0);
    }

    my $total_markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'total_markup',
        description => 'Our total markup over theoretical value',
        set_by      => 'BOM::Product::Contract',
        base_amount => 0,
        %min,
        %max,
    });

    $total_markup->include_adjustment('reset',    $self->model_markup);
    $total_markup->include_adjustment('multiply', $self->commission_adjustment);

    return $total_markup;
}

sub _build_ask_probability {
    my $self = shift;

    return $self->default_probabilities->{ask_probability} if $self->primary_validation_error;

    # Eventually we'll return the actual object.
    # And start from an actual object.
    my $minimum;
    if ($self->pricing_engine_name eq 'Pricing::Engine::TickExpiry') {
        $minimum = 0.4;
    } elsif ($self->pricing_engine_name eq 'BOM::Product::Pricing::Engine::Intraday::Index') {
        $minimum = 0.5 + $self->model_markup->amount;
    } else {
        $minimum = $self->theo_probability->amount;
    }

    # The above is a pretty unacceptable way to acheive this result. You do that stuff at the
    # Engine level.. or work it into your markup.  This is nonsense.

    my $marked_up = Math::Util::CalculatedValue::Validatable->new({
        name        => 'ask_probability',
        description => 'The price we request for this contract.',
        set_by      => 'BOM::Product::Contract',
        minimum     => $minimum,
        maximum     => 1,
    });

    $marked_up->include_adjustment('reset', $self->theo_probability);

    $marked_up->include_adjustment('add', $self->total_markup);

    my $min_allowed_ask_prob = $self->market->deep_otm_threshold;

    if ($marked_up->amount < $min_allowed_ask_prob) {
        my $deep_otm_markup = Math::Util::CalculatedValue::Validatable->new({
            name        => 'deep_otm_markup',
            description => 'Additional markup for deep OTM contracts',
            set_by      => 'BOM::Product::Contract',
            minimum     => 0,
            maximum     => $min_allowed_ask_prob,
            base_amount => $min_allowed_ask_prob - $marked_up->amount,
        });
        $marked_up->include_adjustment('add', $deep_otm_markup);
    }
    my $max_allowed_ask_prob = 1 - $min_allowed_ask_prob;
    if ($marked_up->amount > $max_allowed_ask_prob) {
        my $max_prob_markup = Math::Util::CalculatedValue::Validatable->new({
            name        => 'max_prob_markup',
            description => 'Additional markup for contracts with prob higher that max allowed probability',
            set_by      => __PACKAGE__,
            base_amount => $min_allowed_ask_prob,
        });
        $marked_up->include_adjustment('add', $max_prob_markup);
    }
    # If BS is very high, we don't want that business, even if it makes sense.
    # Also, if the market supplement would absolutely drive us out of [0,1]
    # Then it is nonsense to be ignored.
    if (   $self->bs_probability->amount >= 0.999
        || abs($self->theo_probability->peek_amount('market_supplement') // 0) >= 1
        || ($self->theo_probability->peek_amount('market_supplement') // 0) <= -0.5)
    {
        my $no_business = Math::Util::CalculatedValue::Validatable->new({
            name        => 'too_high_bs_prob',
            description => 'Marked up to drive price to 1 when BS is very high',
            set_by      => __PACKAGE__,
            base_amount => 1,
        });
        $marked_up->include_adjustment('add', $no_business);
    }

    return $marked_up;
}

sub _build_commission_adjustment {
    my $self = shift;

    my $comm_scale = Math::Util::CalculatedValue::Validatable->new({
        name        => 'global_commission_adjustment',
        description => 'Our scaling adjustment to calculated model markup.',
        set_by      => 'BOM::Product::Contract',
        minimum     => (BOM::Platform::Static::Config::quants->{commission}->{adjustment}->{minimum} / 100),
        maximum     => (BOM::Platform::Static::Config::quants->{commission}->{adjustment}->{maximum} / 100),
        base_amount => 0,
    });

    my $adjustment_used = Math::Util::CalculatedValue::Validatable->new({
        name        => 'scaling_factor',
        description => 'Our scaling adjustment to calculated model markup.',
        set_by      => 'quants.commission.adjustment.global_scaling',
        base_amount => (BOM::Platform::Runtime->instance->app_config->quants->commission->adjustment->global_scaling / 100),
    });

    $comm_scale->include_adjustment('reset', $adjustment_used);

    if ($self->built_with_bom_parameters) {
        $comm_scale->include_adjustment(
            'multiply',
            Math::Util::CalculatedValue::Validatable->new({
                    name        => 'bom_created_bet',
                    description => 'We created this bet with the intent to get more action.',
                    minimum     => 0,
                    maximum     => 1,
                    set_by      => 'quants.commission.adjustment.bom_created_bet',
                    base_amount => (BOM::Platform::Static::Config::quants->{commission}->{adjustment}->{bom_created_bet} / 100),
                }));
    }

    return $comm_scale;
}

sub is_valid_to_buy {
    my $self = shift;

    my $valid = $self->confirm_validity;

    return ($self->built_with_bom_parameters) ? $valid : $self->_report_validation_stats('buy', $valid);
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

    if (not $self->is_expired and not $self->opposite_bet->is_valid_to_buy) {
        # Their errors are our errors, now!
        $self->add_error($self->opposite_bet->primary_validation_error);
    }

    if (scalar @{$self->corporate_actions}) {
        $self->add_error({
            message           => format_error_string('affected by corporate action', symbol => $self->underlying->symbol),
            message_to_client => localize("This contract is affected by corporate action."),
        });
    }

    my $passes_validation = $self->primary_validation_error ? 0 : 1;
    return $self->_report_validation_stats('sell', $passes_validation);
}

# PRIVATE method.
#  If your price is payout * some probability, just use this.
sub _price_from_prob {
    my ($self, $prob_method) = @_;
    my $price;
    if ($self->date_pricing->is_after($self->date_start) and $self->is_expired) {
        $price = $self->value;
    } else {
        $price = (defined $self->$prob_method) ? $self->payout * $self->$prob_method->amount : undef;
    }
    return (defined $price) ? roundnear(0.01, $price) : undef;
}

sub _build_ask_price {
    my $self = shift;

    return $self->_price_from_prob('ask_probability');
}

sub _build_payout {
    my $self = shift;

    my $payout            = $self->ask_price / $self->ask_probability->amount;
    my $dollar_commission = $payout * $self->total_markup->amount;
    if ($dollar_commission < 0.02) {
        $payout -= (0.02 - $dollar_commission);
    }

    return roundnear(0.01, $payout);
}

sub _build_theo_probability {
    my $self = shift;

    my $theo;
    # Have to keep it this way until we remove CalculatedValue in Contract.
    if ($self->new_interface_engine) {
        $theo = Math::Util::CalculatedValue::Validatable->new({
            name        => 'theo_probability',
            description => 'theorectical value of a contract',
            set_by      => $self->pricing_engine_name,
            minimum     => 0,
            maximum     => 1,
            base_amount => $self->pricing_engine->theo_probability,
        });
    } else {
        $theo = $self->pricing_engine->probability;
    }

    return $theo;
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

sub _build_model_markup {
    my $self = shift;

    my $model_markup;
    if ($self->new_interface_engine) {
        my $risk_markup = Math::Util::CalculatedValue::Validatable->new({
            name        => 'risk_markup',
            description => 'Risk markup for a pricing model',
            set_by      => $self->pricing_engine_name,
            base_amount => $self->pricing_engine->risk_markup,
        });
        my $commission_markup = Math::Util::CalculatedValue::Validatable->new({
            name        => 'commission_markup',
            description => 'Commission markup for a pricing model',
            set_by      => $self->pricing_engine_name,
            base_amount => $self->pricing_engine->commission_markup,
        });
        if ($self->built_with_bom_parameters) {
            my $sell_discount = Math::Util::CalculatedValue::Validatable->new({
                name        => 'sell_discount',
                description => 'Discount on sell',
                set_by      => __PACKAGE__,
                base_amount => BOM::Platform::Static::Config::quants->{commission}->{resell_discount_factor},
            });
            $commission_markup->include_adjustment('multiply', $sell_discount);
        }
        $model_markup = Math::Util::CalculatedValue::Validatable->new({
            name        => 'model_markup',
            description => 'Risk and commission markup for a pricing model',
            set_by      => $self->pricing_engine_name,
        });
        $model_markup->include_adjustment('reset', $risk_markup);
        $model_markup->include_adjustment('add',   $commission_markup);
    } else {
        $model_markup = $self->pricing_engine->model_markup;
    }

    return $model_markup;
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
    my @barriers = $self->_barriers_for_shortcode;
    push @shortcode_elements, @barriers if @barriers;

    return uc join '_', @shortcode_elements;
}

sub _build_entry_tick {
    my $self = shift;

    my $underlying = $self->underlying;

    $self->hold_for_entry_tick;
    my $hold_seconds = $self->hold_for_entry_tick->seconds;
    my $start = ($hold_seconds) ? $self->effective_start : $self->date_start;
    my $entry_tick;

    if ($hold_seconds or not $self->pricing_new) {
        my $entry_time = $start->epoch;
        my $hold_time  = time + $hold_seconds;
        do {
            if   ($self->is_forward_starting) { $entry_tick = $self->underlying->tick_at($entry_time); }
            else                              { $entry_tick = $self->underlying->next_tick_after($entry_time); }
        } while (not $entry_tick and sleep(0.5) and time <= $hold_time);

    }

    if ($entry_tick) {
        my $when        = $entry_tick->epoch;
        my $max_delay   = $underlying->max_suspend_trading_feed_delay;
        my $start_delay = Time::Duration::Concise::Localize->new(interval => abs($when - $start->epoch));
        if ($start_delay->seconds > $max_delay->seconds) {
            $self->missing_market_data(1);
            $self->add_error({
                    message => format_error_string(
                        'Entry tick too far away',
                        symbol    => $self->underlying->symbol,
                        delay     => $start_delay->as_concise_string,
                        permitted => $max_delay->as_concise_string,
                        start     => $start->datetime,
                    ),
                    message_to_client => localize("Missing market data for entry spot."),
                });
        }
    } elsif ($hold_seconds) {
        $self->add_error({
                message => format_error_string(
                    'No entry tick within limit',
                    limit  => $self->hold_for_entry_tick->as_string,
                    start  => $start->datetime,
                    symbol => $self->underlying->symbol,
                ),
                message_to_client => localize("Prevailing market price cannot be determined."),
            });
    }

    return $entry_tick;
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
    my $barriers_for_pricing = $self->_barriers_for_pricing;
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
        starttime       => $start_date->epoch,
    };

    if ($self->pricing_engine_name eq 'BOM::Product::Pricing::Engine::Intraday::Forex') {
        $args->{average_tick_count}   = $self->average_tick_count;
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
    if ($self->volsurface->type eq 'phased') {
        $vol = $self->volsurface->get_volatility({
            start_epoch => $self->effective_start->epoch,
            end_epoch   => $self->date_expiry->epoch
        });
    } elsif ($pen =~ /VannaVolga/) {
        $vol = $self->volsurface->get_volatility({
            days  => $self->timeindays->amount,
            delta => 50
        });
    } elsif ($pen =~ /Intraday::Forex/) {
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
        $self->average_tick_count($volsurface->average_tick_count);
        if ($volsurface->error) {
            $self->add_error({
                    message => format_error_string(
                        'Too few periods for historical vol calculation',
                        symbol   => $self->underlying->symbol,
                        duration => $self->remaining_time->as_concise_string,
                    ),
                    message_to_client =>
                        localize('Trading on [_1] is suspended due to missing market data.', $self->underlying->translated_display_name()),
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
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
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
        strike => $self->_barriers_for_pricing->{barrier1},
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

sub pricing_spot {
    my $self = shift;

    # Use the entry_tick if we're supposed to wait for it.
    # This will usually happen in a sell-back transaction and reflect the spot at the time of that transaction.
    my $initial_spot = ($self->hold_for_entry_tick->seconds && $self->entry_tick) ? $self->entry_tick->quote : $self->current_spot;

    if (not $initial_spot) {
        # If we could not get the correct spot to price, we will take the latest available spot at pricing time.
        # This is to prevent undefined spot being passed to BlackScholes formula that causes the code to die!!
        $initial_spot = $self->underlying->tick_at($self->date_pricing->epoch, {allow_inconsistent => 1});
        $initial_spot //= $self->underlying->pip_size;
        $self->add_error({
                message => format_error_string(
                    'Undefined spot',
                    'date pricing' => $self->date_pricing->datetime,
                    symbol         => $self->underlying->symbol
                ),
                message_to_client => localize('We could not process this contract at this time.'),
            });
    }

    if ($self->underlying->market->prefer_discrete_dividend) {
        $initial_spot += $self->dividend_adjustment->{spot};
    }

    return $initial_spot;
}

has offering_specifics => (
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
    };

    if ($self->category->code eq 'callput') {
        $filter->{barrier_category} = ($self->is_atm_bet) ? 'euro_atm' : 'euro_non_atm';
    } else {
        $filter->{barrier_category} = $BOM::Product::Offerings::BARRIER_CATEGORIES->{$self->category->code}->[0];
    }
    return get_contract_specifics($filter);
}

=head2 _payout_limit

Returns a limit for the payout if one exists on the contract

=cut

sub _payout_limit {
    my ($self) = @_;

    return $self->offering_specifics->{payout_limit}->{$self->currency};    # Even if not valid, make it 100k.
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

    my @possible_payout_maxes = ($self->_payout_limit);

    my $bet_limits = BOM::Platform::Static::Config::quants->{bet_limits};
    push @possible_payout_maxes, $bet_limits->{maximum_payout}->{$curr};
    push @possible_payout_maxes, $bet_limits->{maximum_payout_on_new_markets}->{$curr}
        if ($underlying->is_newly_added);
    push @possible_payout_maxes, $bet_limits->{maximum_payout_on_less_than_7day_indices_call_put}->{$curr}
        if ($self->underlying->market->name eq 'indices' and not $self->is_atm_bet and $self->timeindays->amount < 7);

    my $payout_max = min(grep { looks_like_number($_) } @possible_payout_maxes);
    my $stake_max = $payout_max;

    # Client likes lower stake/payout limit on random market.
    my $payout_min =
        ($self->underlying->market->name eq 'random')
        ? $bet_limits->{min_payout}->{random}->{$curr}
        : $bet_limits->{min_payout}->{default}->{$curr};
    my $stake_min = ($self->built_with_bom_parameters) ? $payout_min / 20 : $payout_min / 2;

    # err is included here to allow the web front-end access to the same message generated in the back-end.
    return {
        stake => {
            min => $stake_min,
            max => $stake_max,
            err => ($self->built_with_bom_parameters)
            ? localize('Contract market price is too close to final payout.')
            : localize(
                'Buy price must be between [_1] and [_2].',
                to_monetary_number_format($stake_min, 1),
                to_monetary_number_format($stake_max, 1)
            ),
        },
        payout => {
            min => $payout_min,
            max => $payout_max,
            err => localize(
                'Payout must be between [_1] and [_2].',
                to_monetary_number_format($payout_min, 1),
                to_monetary_number_format($payout_max, 1)
            ),
        },
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
        strikes           => [grep { $_ } values %{$self->_barriers_for_pricing}],
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
            my $utils = BOM::MarketData::VolSurface::Utils->new;
            return $utils->effective_date_for($expiry)->days_between($utils->effective_date_for($start));
        },
        get_rollover_time => sub {
            my $when = shift;
            return BOM::MarketData::VolSurface::Utils->new->NY1700_rollover_date_on($when);
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
            if ($volsurface->type eq 'phased') {
                $vol = $volsurface->get_volatility({
                    start_epoch => $effective_start->epoch,
                    end_epoch   => $date_expiry->epoch
                });
            } elsif ($surface_data) {
                my $new_volsurface_obj = $volsurface->clone({surface => $surface_data});
                $vol = $new_volsurface_obj->get_volatility($args);
            } else {
                $vol = $volsurface->get_volatility($args);
            }

            return $vol;
        },
        get_atm_volatility => sub {
            my $args = shift;
            my $vol;
            if ($volsurface->type eq 'phased') {
                $vol = $volsurface->get_volatility({
                    start_epoch => $effective_start->epoch,
                    end_epoch   => $date_expiry->epoch
                });
            } else {
                $args->{delta} = 50;
                $vol = $volsurface->get_volatility($args);
            }

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
                    chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
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
            symbol   => $self->underlying->market->name,
            for_date => $self->underlying->for_date
        };
        my $rho_data = BOM::MarketData::CorrelationMatrix->new($construct_args);

        my $index           = $self->underlying->asset_symbol;
        my $payout_currency = $self->currency;
        my $tiy             = $self->timeinyears->amount;
        $rhos{fd_dq} = $rho_data->correlation_for($index, $payout_currency, $tiy);
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
    );
    my $curr_obj = BOM::Market::Currency->new(%args);

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

    return Time::Duration::Concise::Localize->new(
        interval => max(0, $end_point->epoch - $from->epoch),
        locale   => BOM::Platform::Context::request()->language
    );
}

=head2 barrier_display_info

Given a tick break down how the barriers relate.

=cut

sub barrier_display_info {
    my ($self, $tick) = @_;

    my $underlying = $self->underlying;
    my $spot = defined $tick ? $tick->quote : undef;
    my @barriers;
    if ($self->two_barriers) {
        push @barriers, {barrier  => $self->high_barrier->as_absolute} if $self->high_barrier;
        push @barriers, {barrier2 => $self->low_barrier->as_absolute}  if $self->low_barrier;
    } else {
        @barriers = $self->barrier ? ({barrier => $self->barrier->as_absolute}) : ();
    }

    my %barriers;
    if ($spot) {
        foreach my $barrier (@barriers) {
            my $which  = keys %$barrier;
            my $strike = values %$barrier;
            $barriers{$which}->{amnt} = $underlying->pipsized_value($strike);
            $barriers{$which}->{dir}  = ($spot > $strike) ? localize('minus') : ($spot < $strike) ? localize('plus') : '';
            $barriers{$which}->{diff} = $underlying->pipsized_value(abs($spot - $strike)) || '';                             # Do not show 0 for 0.
            $barriers{$which}->{desc} =
                !$self->two_barriers ? localize('barrier') : $strike > $spot ? localize('high barrier') : localize('low barrier');
        }
    }

    return (barriers => \%barriers);
}

has exit_tick => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_exit_tick {
    my $self = shift;

    my $underlying = $self->underlying;
    my $exchange   = $self->exchange;

    my $exit_tick;
    if ($self->tick_expiry) {
        my $tick_number       = $self->ticks_to_expiry;
        my @ticks_since_start = @{
            $underlying->ticks_in_between_start_limit({
                    start_time => $self->date_start->epoch + 1,
                    limit      => $tick_number,
                })};
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

    if ($exit_tick and my $entry_tick = $self->entry_tick) {
        my ($first_date, $last_date) = map { Date::Utility->new($_) } ($entry_tick->epoch, $exit_tick->epoch);
        my $max_delay = $underlying->max_suspend_trading_feed_delay;
        # We should not have gotten here otherwise.
        if (not $first_date->is_before($last_date)) {
            $self->missing_market_data(1);
            $self->add_error({
                    message => format_error_string(
                        'Start tick is not before expiry tick',
                        symbol => $underlying->symbol,
                        start  => $first_date->datetime,
                        expiry => $last_date->datetime
                    ),
                    message_to_client => localize("Missing market data for contract period."),
                });
        }
        my $end_delay = Time::Duration::Concise->new(interval => $self->date_expiry->epoch - $last_date->epoch);

        if ($self->expiry_daily and not $underlying->use_official_ohlc) {
            if (    not $self->is_path_dependent
                and not $self->_has_ticks_before_close($exchange->closing_on($self->date_expiry)))
            {
                $self->missing_market_data(1);
                $self->add_error({
                        message => format_error_string(
                            'Missing ticks at close',
                            symbol => $underlying->symbol,
                            expiry => $self->date_expiry->datetime
                        ),
                        message_to_client => localize("Missing market data for exit spot."),
                    });
            }
        } elsif ($end_delay->seconds > $max_delay->seconds) {
            $self->missing_market_data(1);
            $self->add_error({
                    message => format_error_string(
                        'Exit tick too far away',
                        symbol    => $underlying->symbol,
                        delay     => $end_delay->as_concise_string,
                        permitted => $max_delay->as_concise_string,
                        expiry    => $self->date_expiry->datetime
                    ),
                    message_to_client => localize("Missing market data for exit spot."),
                });
        }
        if (not $self->expiry_daily and $underlying->intradays_must_be_same_day and $exchange->trading_days_between($first_date, $last_date)) {
            $self->add_error({
                    message => format_error_string(
                        'Exit tick date differs from entry tick date on intraday',
                        symbol => $underlying->symbol,
                        start  => $last_date->datetime,
                        expiry => $first_date->datetime,
                    ),
                    message_to_client => localize("Intraday contracts may not cross market open."),
                });
        }
        if ($self->tick_expiry) {
            my $actual_duration = Time::Duration::Concise->new(interval => $last_date->epoch - $first_date->epoch);
            if ($actual_duration->seconds > $self->max_tick_expiry_duration->seconds) {
                $self->missing_market_data(1);
                $self->add_error({
                        message => format_error_string(
                            'Tick expiry duration exceeds permitted maximum',
                            symbol    => $underlying->symbol,
                            actual    => $actual_duration->as_concise_string,
                            permitted => $self->max_tick_expiry_duration->as_concise_string
                        ),
                        message_to_client => localize("Missing market data for contract period."),
                    });
            }
        }
    }

    return $exit_tick;
}

sub _has_ticks_before_close {
    my ($self, $closing) = @_;

    my $underlying = $self->underlying;

    my $closing_tick = $underlying->tick_at($closing->epoch, {allow_inconsistent => 1});

    return (defined $closing_tick and $closing->epoch - $closing_tick->epoch > $underlying->max_suspend_trading_feed_delay->seconds) ? 0 : 1;
}

# Validation methods.

sub _validate_underlying {
    my $self = shift;

    my @errors;
    my $underlying      = $self->underlying;
    my $translated_name = $underlying->translated_display_name();

    if (BOM::Platform::Runtime->instance->app_config->system->suspend->trading) {
        push @errors,
            {
            message           => format_error_string('All trading suspended on system'),
            message_to_client => localize("Trading is suspended at the moment."),
            };
    }
    if ($underlying->is_trading_suspended) {
        push @errors,
            {
            message           => format_error_string('Underlying trades suspended',      symbol => $underlying->symbol),
            message_to_client => localize('Trading on [_1] is suspended at the moment.', $translated_name),
            };
    }

    if (grep { $_ eq $underlying->symbol } @{BOM::Platform::Runtime->instance->app_config->quants->underlyings->disabled_due_to_corporate_actions}) {
        push @errors,
            {
            message => format_error_string('Underlying trades suspended due to corporate actions', symbol => $underlying->symbol),
            message_to_client => localize('Trading on [_1] is suspended at the moment.', $translated_name),
            };
    }

    # Ignore spot age if it's an expired bet.
    if (not $self->is_expired) {
        if (not $self->current_tick) {
            push @errors,
                {
                message           => format_error_string('No realtime data',                              symbol => $underlying->symbol),
                message_to_client => localize('Trading on [_1] is suspended due to missing market data.', $translated_name),
                };
        } elsif ($self->exchange->is_open_at($self->date_pricing)
            and $self->date_pricing->epoch - $underlying->max_suspend_trading_feed_delay->seconds > $self->current_tick->epoch)
        {
            # only throw errors for quote too old, if the exchange is open at pricing time
            push @errors,
                {
                message           => format_error_string('Quote too old',                                 symbol => $underlying->symbol),
                message_to_client => localize('Trading on [_1] is suspended due to missing market data.', $translated_name),
                };
        }
    }

    if ($self->is_intraday and $underlying->deny_purchase_during($self->date_start, $self->date_expiry)) {
        push @errors,
            {
            message           => format_error_string('Underlying buy trades suspended for period', symbol => $underlying->symbol),
            message_to_client => localize('Trading on [_1] is suspended at the moment.',           $translated_name),
            info_link => request()->url_for('/resources/market_timesws', undef, {no_host => 1}),
            info_text => localize('Trading Times'),
            };
    }

    return @errors;
}

sub _validate_contract {
    my $self = shift;

    my @errors;
    my $contract_code = $self->code;
    # check if trades are suspended on that claimtype
    my $suspend_claim_types = BOM::Platform::Runtime->instance->app_config->quants->features->suspend_claim_types;
    if ($suspend_claim_types and first { $contract_code eq $_ } @{$suspend_claim_types}) {
        push @errors,
            {
            message           => format_error_string('Trading suspended for contract type', code => $contract_code),
            message_to_client => localize("Trading is suspended at the moment."),
            };
    }
    my $expiry_type = $self->expiry_type;
    if (not $self->offering_specifics->{permitted}) {
        my $message =
            ($self->built_with_bom_parameters)
            ? localize('Resale of this contract is not offered.')
            : localize('This trade is not offered.');
        push @errors,
            {
            message => format_error_string(
                'trying unauthorised combination',
                underlying  => $self->underlying->symbol,
                expiry_type => $expiry_type,
                code        => $contract_code,
            ),
            message_to_client => $message,
            };
    }

    return @errors;
}

sub _validate_payout {
    my $self = shift;

    my @errors;

    # Extant contracts can have whatever payouts were OK then.
    return @errors if ($self->built_with_bom_parameters);

    my $bet_payout      = $self->payout;
    my $payout_currency = $self->currency;
    my $limits          = $self->staking_limits->{payout};
    my $payout_max      = $limits->{max};
    my $payout_min      = $limits->{min};

    if (not first { $_ eq $payout_currency } @{request()->available_currencies}) {
        push @errors,
            {
            message           => format_error_string('Bad payout currency', currency => $payout_currency),
            message_to_client => localize('Invalid payout currency.'),
            };
    }

    if ($bet_payout < $payout_min or $bet_payout > $payout_max) {
        push @errors,
            {
            message => format_error_string(
                'payout amount outside acceptable range',
                given => $bet_payout,
                min   => $payout_min,
                max   => $payout_max
            ),
            message_to_client => $limits->{err},
            };
    }

    my $payout_as_string = "" . $bet_payout;    #Just to be sure we're deailing with a string.
    $payout_as_string =~ s/[\.0]+$//;           # Strip trailing zeroes and decimal points to be more friendly.

    if ($bet_payout =~ /\.[0-9]{3,}/) {
        # We did the best we could to clean up looks like still too many decimals
        push @errors,
            {
            message => format_error_string(
                'payout amount has too many decimal places',
                permitted => 2,
                payout    => $bet_payout
            ),
            message_to_client => localize('Payout may not have more than two decimal places.',),
            };
    }

    return @errors;
}

sub _validate_stake {
    my $self = shift;

    my @errors;

    my $contract_stake  = $self->ask_price;
    my $contract_payout = $self->payout;
    my $limits          = $self->staking_limits->{stake};

    push @errors, $self->ask_probability->all_errors if (not $self->ask_probability->confirm_validity);

    my $stake_minimum = $limits->{min};
    my $stake_maximum = $limits->{max};

    if (not $contract_stake) {
        push @errors,
            {
            message           => format_error_string('Empty or zero stake', stake => $contract_stake),
            message_to_client => localize("Invalid stake"),
            };
    }

    if ($contract_stake < $stake_minimum or $contract_stake > $stake_maximum) {
        push @errors,
            {
            message => format_error_string(
                'stake is not within limits',
                stake => $contract_stake,
                min   => $stake_minimum,
                max   => $stake_maximum
            ),
            message_to_client => $limits->{err},
            };
    }

    # Compared as strings of maximum visible client currency width to avoid floating-point issues.
    if (sprintf("%.2f", $contract_stake) eq sprintf("%.2f", $contract_payout)) {
        my $message = ($self->built_with_bom_parameters) ? localize('Current market price is 0.') : localize('This contract offers no return.');
        push @errors,
            {
            message           => format_error_string('stake same as payout'),
            message_to_client => $message,
            };
    }

    return @errors;
}

# Check against our timelimits, suspended trades etc. whether we allow this bet to start
sub _validate_start_date {
    my $self = shift;
    my @errors;
    my $underlying = $self->underlying;

    $underlying->sod_blackout_start;

    my $exchange     = $self->exchange;
    my $epoch_start  = $self->date_start->epoch;
    my $epoch_expiry = $self->date_expiry->epoch;

    my $expiry_closing            = $exchange->closing_on($self->date_expiry);
    my $start_date_closing        = $exchange->closing_on($self->date_start);
    my $sec_to_close              = ($expiry_closing) ? $expiry_closing->epoch - $self->date_pricing->epoch : 0;
    my $start_date_sec_to_close   = ($start_date_closing) ? $start_date_closing->epoch - $self->date_pricing->epoch : 0;
    my $when                      = $self->date_pricing;
    my $forward_starting_blackout = Time::Duration::Concise::Localize->new(
        interval => '5m',
        locale   => BOM::Platform::Context::request()->language
    );
    my $eod_blackout_start =
          ($self->tick_expiry and $underlying->intradays_must_be_same_day) ? $self->max_tick_expiry_duration
        : ($self->date_expiry->date eq $self->date_pricing->date) ? $underlying->eod_blackout_start
        :                                                           undef;
    # Contracts must be held for a minimum duration before resale.
    if (my $orig_start = $self->build_parameters->{_original_date_start}) {
        # Does not apply to unstarted forward-starting contracts
        my $time = $self->_date_pricing_milliseconds // $self->date_pricing->epoch;
        if ($time > $orig_start->epoch) {
            my $minimum_hold = Time::Duration::Concise::Localize->new(
                interval => '1m',
                locale   => BOM::Platform::Context::request()->language
            );
            my $held = Time::Duration::Concise::Localize->new(interval => $epoch_start - $orig_start->epoch);
            if ($held->seconds < $minimum_hold->seconds) {
                push @errors, {
                    message => format_error_string(
                        'Contract not held long enough',
                        held => $held->as_concise_string,
                        min  => $minimum_hold->as_concise_string,
                    ),
                    message_to_client => localize('Contract must be held for [_1] before resale is offered.', $minimum_hold->as_string),

                };
            }
        }
    }

    if (not $epoch_expiry > $epoch_start) {
        push @errors,
            {
            message => format_error_string(
                'Start must be before expiry',
                'start' => $epoch_start,
                expiry  => $epoch_expiry
            ),
            message_to_client => localize("Expiry time cannot be in the past."),
            };
    }

    if (not $self->is_forward_starting and $epoch_start > $when->epoch) {
        push @errors,
            {
            message           => format_error_string('Forward time for non-forward-starting contract type', code => $self->code),
            message_to_client => localize('Start time is invalid.'),
            };
    }
    # Bet can not start in the past
    if (not $self->built_with_bom_parameters and $epoch_start < $when->epoch) {
        push @errors,
            {
            message           => format_error_string('starts in the past'),
            message_to_client => localize("Start time is in the past"),
            };
    }
    # exchange needs to be open when the bet starts.
    if (not $exchange->is_open_at($self->date_start)) {
        my $message =
            ($self->is_forward_starting) ? localize("The market must be open at the start time.") : localize('This market is presently closed.');
        push @errors,
            {
            message => format_error_string(
                'underlying is closed at start',
                symbol => $self->underlying->symbol,
                start  => $self->date_start->datetime
            ),
            message_to_client => $message . " " . localize("Try out the Random Indices which are always open.")};
    } elsif (my $open_seconds = ($exchange->seconds_since_open_at($self->date_start) // 0) < $underlying->sod_blackout_start->seconds) {
        my $blackout_time = $underlying->sod_blackout_start->as_string;
        push @errors,
            {
            message => format_error_string(
                'underlying in starting blackout',
                symbol   => $underlying->symbol,
                blackout => $blackout_time
            ),
            message_to_client => localize("Trading is available after the first [_1] of the session.", $blackout_time) . " "
                . localize("Try out the Random Indices which are always open.")};
    } elsif ($self->is_forward_starting and not $self->built_with_bom_parameters) {
        # Intraday cannot be bought in the 5 mins before the bet starts, unless we've built it for that purpose.
        if ($epoch_start < $when->epoch + $forward_starting_blackout->seconds) {
            push @errors,
                {
                message => format_error_string('forward-starting blackout', 'blackout' => $forward_starting_blackout->as_concise_string),
                message_to_client =>
                    localize("Start time on forward-starting contracts must be more than [_1] from now.", $forward_starting_blackout->as_string),
                };
        }
    } elsif ($eod_blackout_start and $sec_to_close < $eod_blackout_start->seconds) {
        my $localized_eod_blackout_start = Time::Duration::Concise::Localize->new(
            interval => $eod_blackout_start->seconds,
            locale   => BOM::Platform::Context::request()->language
        );
        push @errors,
            {
            message => format_error_string(
                'end of day start blackout',
                symbol           => $underlying->symbol,
                min              => $eod_blackout_start->as_concise_string,
                'actual seconds' => $sec_to_close
            ),
            message_to_client => localize("Trading suspended for the last [_1] of the session.", $localized_eod_blackout_start->as_string),
            info_link => request()->url_for('/resources/market_timesws', undef, {no_host => 1}),
            info_text => localize('Trading Times'),
            };
    } elsif ($underlying->market->name eq 'indices' and not $self->is_intraday and not $self->is_atm_bet and $self->timeindays->amount <= 7) {
        if ($start_date_sec_to_close < 3600) {
            push @errors,
                {
                message => format_error_string(
                    'end of day start blackout',
                    symbol           => $underlying->symbol,
                    'actual seconds' => $start_date_sec_to_close
                ),
                message_to_client => localize("Trading on this contract type is suspended for the last one hour of the session."),
                info_link         => request()->url_for('/resources/market_timesws', undef, {no_host => 1}),
                info_text         => localize('Trading Times'),
                };
        }

    }

    if ($self->is_intraday and not $self->is_atm_bet and $self->underlying->market->name eq 'forex') {
        my $start_epoch = $self->effective_start->epoch;
        if (my $tentative = first { $start_epoch >= $_->{blankout} and $start_epoch <= $_->{blankout_end} } @{$self->tentative_events}) {
            push @errors,
                {
                message           => format_error_string('tentative economic events blackout period'),
                message_to_client => localize(
                    "Trading is suspended for [_1] from [_2] to [_3]",     $self->underlying->translated_display_name,
                    Date::Utility->new($tentative->{blankout})->time_hhmm, Date::Utility->new($tentative->{blankout_end})->time_hhmm
                ),
                };
        }
    }

    return @errors;
}

sub _validate_expiry_date {
    my $self = shift;

    my @errors;
    my $underlying   = $self->underlying;
    my $epoch_expiry = $self->date_expiry->epoch;
    my $exchange     = $self->exchange;
    my $times_text   = localize('Trading Times');

    if ($self->is_expired and not $self->is_path_dependent) {
        push @errors,
            {
            message           => format_error_string('already expired contract'),
            message_to_client => localize("Contract has already expired."),
            };
    } elsif ($self->is_intraday) {
        if (not $exchange->is_open_at($self->date_expiry)) {
            my $times_link = request()->url_for('/resources/market_timesws', undef, {no_host => 1});
            push @errors,
                {
                message => format_error_string(
                    'underlying closed at expiry',
                    symbol => $self->underlying->symbol,
                    expiry => $self->date_expiry->datetime
                ),
                message_to_client => localize("Contract must expire during trading hours."),
                info_link         => $times_link,
                info_text         => $times_text,
                };
        } else {
            my $eod_blackout_expiry = $self->underlying->eod_blackout_expiry;
            my $expiry_before_close = Time::Duration::Concise::Localize->new(
                interval => $exchange->closing_on($self->date_expiry)->epoch - $epoch_expiry,
                locale   => BOM::Platform::Context::request()->language
            );
            my $closing = $exchange->closing_on($self->date_start);
            if ($closing and $underlying->intradays_must_be_same_day and $closing->epoch < $self->date_expiry->epoch) {
                push @errors,
                    {
                    message           => format_error_string('Intraday duration must expire on same day', symbol => $underlying->symbol),
                    message_to_client => localize(
                        'Contracts on [_1] with durations under 24 hours must expire on the same trading day.',
                        $underlying->translated_display_name()
                    ),
                    };
            } elsif ($expiry_before_close->minutes < $eod_blackout_expiry->minutes) {
                my $times_link = request()->url_for('/resources/market_timesws', undef, {no_host => 1});
                push @errors,
                    {
                    message => format_error_string(
                        'end of day expiration blackout',
                        symbol => $underlying->symbol,
                        min    => $eod_blackout_expiry->as_concise_string,
                        actual => $expiry_before_close->as_concise_string
                    ),
                    message_to_client => localize("Contract may not expire within the last [_1] of trading.", $eod_blackout_expiry->as_string),
                    info_link         => $times_link,
                    info_text         => $times_text,
                    };
            }
        }

        if (not $self->is_atm_bet and $self->underlying->market->name eq 'forex') {
            my $expiry_epoch = $self->date_expiry->epoch;
            if (my $tentative = first { $expiry_epoch >= $_->{blankout} and $expiry_epoch <= $_->{blankout_end} } @{$self->tentative_events}) {
                push @errors,
                    {
                    message           => format_error_string('tentative economic events blackout period'),
                    message_to_client => localize(
                        "Trading is suspended for [_1] from [_2] to [_3]",     $self->underlying->translated_display_name,
                        Date::Utility->new($tentative->{blankout})->time_hhmm, Date::Utility->new($tentative->{blankout_end})->time_hhmm
                    ),
                    };
            }
        }
    } elsif ($self->expiry_daily) {
        my $close = $self->underlying->exchange->closing_on($self->date_expiry);
        # if it is not a trading day at expiry, we will catch that later.
        if ($close and not $close->is_same_as($self->date_expiry)) {
            push @errors,
                {
                message => format_error_string(
                    'daily expiry must expire at close',
                    expiry => $self->date_expiry->datetime,
                    close  => $close->datetime
                ),
                message_to_client => localize(
                    'Contracts on [_1] with duration more than 24 hours must expire at the end of a trading day.',
                    $underlying->translated_display_name()
                ),
                };
        }
    }

    return @errors;
}

sub _validate_lifetime {
    my $self = shift;

    return
          ($self->tick_expiry)   ? $self->_subvalidate_lifetime_tick_expiry
        : (!$self->expiry_daily) ? $self->_subvalidate_lifetime_intraday
        :                          $self->_subvalidate_lifetime_days;
}

sub _subvalidate_lifetime_tick_expiry {
    my $self = shift;

    my @errors;
    my $expiries = $self->permitted_expiries;

    my $min_tick = $expiries->{min} // 0;    # Do we accidentally autoviv here?
    my $max_tick = $expiries->{max} // 0;
    my $invalid_duration_message =
        $min_tick == 0
        ? localize('Trading is not offered for this duration')
        : localize('Number of ticks must be between [_1] and [_2]', $min_tick, $max_tick);
    my $tick_count = $self->tick_count;

    if ($tick_count > $max_tick or $tick_count < $min_tick) {
        push @errors,
            {
            message => format_error_string(
                'Invalid tick count for tick expiry',
                actual => $tick_count,
                min    => $min_tick,
                max    => $max_tick
            ),
            message_to_client => $invalid_duration_message,
            };
    } elsif (my $entry = $self->entry_tick and my $exit = $self->exit_tick) {
        my $actual_duration = Time::Duration::Concise::Localize->new(interval => $exit->epoch - $entry->epoch);
        if ($actual_duration->seconds > $self->max_tick_expiry_duration->seconds) {
            push @errors,
                {
                message => format_error_string(
                    'Tick expiry duration exceeds permitted maximum',
                    actual    => $actual_duration->as_concise_string,
                    permitted => $self->max_tick_expiry_duration->as_concise_string,
                    symbol    => $self->underlying->symbol
                ),
                message_to_client => localize("Missing market data for contract period."),
                };
        }
    }

    return @errors;
}

sub _subvalidate_lifetime_intraday {
    my $self = shift;

    my @errors;
    my $expiries_ref = $self->permitted_expiries;
    my $duration = $self->get_time_to_expiry({from => $self->date_start})->seconds;

    # This might be empty because we don't have short-term expiries on some contracts, even though
    # it's a valid bet type for multi-day contracts.
    my $shortest = Time::Duration::Concise::Localize->new(
        interval => ($expiries_ref->{min}) ? $expiries_ref->{min}->as_concise_string : 0,
        locale => BOM::Platform::Context::request()->language
    );
    my $longest = Time::Duration::Concise::Localize->new(
        interval => ($expiries_ref->{max}) ? $expiries_ref->{max}->as_concise_string : 0,
        locale => BOM::Platform::Context::request()->language
    );
    if ($self->built_with_bom_parameters) {
        if ($shortest->seconds == 0) {
            # Apparently not offered after conversion from ATM
            push @errors,
                {
                message           => format_error_string('Intraday resale not permitted'),
                message_to_client => localize('Resale of this contract is not offered.')};
        } elsif ($duration < $shortest->seconds) {
            push @errors,
                {
                message           => format_error_string('Intraday resale too short'),
                message_to_client => localize('Resale of this contract is not offered with less than [_1] remaining.', $shortest->as_string)};
        }
    } else {
        if (not keys %$expiries_ref or $duration < $shortest->seconds or $duration > $longest->seconds) {
            my $asset_text = localize('Asset Index');
            my $asset_link = request()->url_for('/resources/asset_indexws', undef, {no_host => 1});
            push @errors,
                {
                message => format_error_string(
                    'Intraday duration not acceptable',
                    'duration seconds' => $duration,
                    symbol             => $self->underlying->symbol,
                    code               => $self->code
                ),
                message_to_client => localize('Trading is not offered for this duration.'),
                info_link         => $asset_link,
                info_text         => $asset_text,
                };
        }

    }

    return @errors;
}

sub _subvalidate_lifetime_days {
    my $self = shift;

    my @errors;
    my $underlying  = $self->underlying;
    my $exchange    = $underlying->exchange;
    my $date_expiry = $self->date_expiry;
    my $date_start  = $self->date_start;

    my $expiries_ref = $self->permitted_expiries;

    my $no_time = Time::Duration::Concise::Localize->new(
        interval => '0',
        locale   => BOM::Platform::Context::request()->language
    );
    my $min = $expiries_ref->{min} // $no_time;
    my $max = $expiries_ref->{max} // $no_time;

    my $duration_days = $exchange->trading_date_for($date_expiry)->days_between($exchange->trading_date_for($date_start));

    if ($duration_days < $min->days or $duration_days > $max->days) {
        if ($duration_days > $max->days) {
            $self->date_expiry($exchange->closing_on($self->date_start->plus_time_interval($max->days . 'd')));
        }
        my $message =
            ($self->built_with_bom_parameters)
            ? localize('Resale of this contract is not offered.')
            : localize("Trading is not offered for this duration.");
        my $asset_text = localize('Asset Index');
        my $asset_link = request()->url_for('/resources/asset_indexws', undef, {no_host => 1});
        push @errors,
            {
            message => format_error_string(
                'Daily duration is outside acceptable range',
                actual => $duration_days,
                min    => $min->as_concise_string,
                max    => $max->as_concise_string
            ),
            message_to_client => $message,
            info_link         => $asset_link,
            info_text         => $asset_text,
            };
    }
    if (not $self->is_atm_bet) {
        # For definite ATM contracts we do not have to check for upcoming holidays.
        my $times_text    = localize('Trading Times');
        my $trading_days  = $self->exchange->trading_days_between($date_start, $date_expiry);
        my $holiday_days  = $self->exchange->holiday_days_between($date_start, $date_expiry);
        my $calendar_days = $date_expiry->days_between($date_start);

        if ($calendar_days <= 7 and $holiday_days > 0) {
            my $safer_expiry = $underlying->trade_date_after($self->date_pricing->plus_time_interval('7d'));
            my $message =
                ($self->built_with_bom_parameters)
                ? localize('Resale of this contract is not offered due to market holiday during contract period.')
                : localize("Market holiday during the contract period. Select an expiry date after [_1].", $safer_expiry->date);
            # It's only safer, not safe, because if there are more holidays it still might go nuts.
            my $times_link = request()->url_for('/resources/market_timesws', undef, {no_host => 1});
            push @errors,
                {
                message           => format_error_string('underlying holidays in contract period', symbol => $self->underlying->symbol),
                message_to_client => $message,
                info_link         => $times_link,
                info_text         => $times_text,
                };
        } elsif ($underlying->market->equity and $trading_days <= 4 and $holiday_days >= 2) {
            my $safer_expiry = $date_expiry;
            my $trade_count  = $trading_days;
            while ($trade_count < 4) {
                $safer_expiry = $underlying->trade_date_after($safer_expiry);
                $trade_count++;
            }
            my $message =
                ($self->built_with_bom_parameters)
                ? localize('Resale of this contract is not offered due to market holidays during contract period.')
                : localize("Too many market holidays during the contract period. Select an expiry date after [_1].", $safer_expiry->date);
            my $times_link = request()->url_for('/resources/market_timesws', undef, {no_host => 1});
            push @errors,
                {
                message => format_error_string(
                    'Not enough trading days for calendar days',
                    trading  => $trading_days,
                    calendar => $calendar_days,
                ),
                message_to_client => $message,
                info_link         => $times_link,
                info_text         => $times_text,
                };
        }
    }
    if (
            $underlying->market->equity
        and $date_start->day_of_year >= BOM::Platform::Static::Config::quants->{bet_limits}->{holiday_blackout_start}
        and (  $date_expiry->day_of_year > $date_start->day_of_year
            or $date_expiry->day_of_year <= BOM::Platform::Static::Config::quants->{bet_limits}->{holiday_blackout_end}))
    {
        # Assumes that the black out period always extends over Jan 1 into the next year.
        my $year = $date_expiry->year;
        $year-- if ($date_expiry->day_of_year < $date_start->day_of_year);    # Expiry is into next year, already.
        my $end_of_bo =
            Date::Utility->new('31-Dec-' . $year)
            ->plus_time_interval(BOM::Platform::Static::Config::quants->{bet_limits}->{holiday_blackout_end} . 'd');
        my $message =
            ($self->built_with_bom_parameters)
            ? localize('Resale of this contract is not offered due to end-of-year market holidays.')
            : localize('Contract can not expire during the end-of-year holiday period. Select an expiry date after [_1].', $end_of_bo->date);
        push @errors,
            {
            message => format_error_string(
                'contained within holiday blackout period',
                'blackout start' => $date_start->datetime,
                'blackout end'   => $date_expiry->datetime,
            ),
            message_to_client => $message,
            };
    }

    return @errors;
}

sub _validate_volsurface {
    my $self = shift;

    my @errors;

    if ($self->build_parameters->{pricing_vol}) {
        push @errors,
            {
            message           => format_error_string('forced (not calculated) IV'),
            message_to_client => localize("Prevailing market price cannot be determined."),
            };
    }

    return @errors if $self->market->name eq 'random';

    my $surface          = $self->volsurface;
    my $now              = $self->date_pricing;
    my $standard_message = localize('Trading on [_1] is suspended due to missing market data.', $self->underlying->translated_display_name());
    my $surface_age      = Time::Duration::Concise::Localize->new(
        interval => $now->epoch - $surface->recorded_date->epoch,
        locale   => BOM::Platform::Context::request()->language
    );

    if ($surface->get_smile_flags) {
        push @errors,
            {
            message           => format_error_string('Volsurface has smile flags', symbol => $self->underlying->symbol),
            message_to_client => $standard_message,
            };
    }
    if (    $self->market->name eq 'forex'
        and $self->pricing_engine_name !~ /Intraday::Forex/
        and $self->timeindays->amount < 4
        and $surface_age->hours > 6)
    {
        push @errors,
            {
            message => format_error_string(
                'volsurface too old',
                symbol => $self->underlying->symbol,
                age    => $surface_age->as_concise_string,
                max    => '6h'
            ),
            message_to_client => $standard_message,
            };
    } elsif ($self->market->name eq 'indices' and $surface_age->hours > 24 and not $self->is_atm_bet) {
        push @errors,
            {
            message => format_error_string(
                'volsurface too old',
                symbol => $self->underlying->symbol,
                age    => $surface_age->as_concise_string,
                max    => '4h',
            ),
            message_to_client => $standard_message,
            };
    } elsif ($surface->recorded_date->days_between($self->exchange->trade_date_before($now)) < 0) {
        push @errors,
            {
            message => format_error_string(
                'volsurface too old',
                symbol          => $self->underlying->symbol,
                'recorded date' => $surface->recorded_date->datetime,
                'trade date'    => $now->datetime
            ),
            message_to_client => $standard_message,
            };
    }

    if ($self->volsurface->type eq 'moneyness') {
        if (abs($surface->spot_reference - $self->current_spot) / $self->current_spot * 100 > 5) {
            push @errors,
                {
                message => format_error_string(
                    'spot too far from surface reference',
                    symbol              => $self->underlying->symbol,
                    spot                => $self->current_spot,
                    'surface reference' => $surface->spot_reference
                ),
                message_to_client => $standard_message,
                };
        }
    }

    return @errors;
}

sub _validate_eod_market_risk {
    my $self = shift;

    my @errors;
    my $ny_1700 = BOM::MarketData::VolSurface::Utils->new->NY1700_rollover_date_on($self->date_start);
    my $ny_1600 = $ny_1700->minus_time_interval('1h');

    if (
        first { $self->market->name eq $_ } (qw(forex commodities))
            and $self->timeindays->amount <= 3
        and (
            $ny_1600->is_before($self->date_start)
            or (    $self->is_intraday
                and $ny_1600->is_before($self->date_expiry)))
        and not $self->is_atm_bet
        )
    {
        my $message =
            ($self->built_with_bom_parameters)
            ? localize('Resale of this contract is not offered.')
            : localize('The contract is not available after [_1] GMT.', $ny_1600->time_hhmm);
        push @errors,
            {
            message => format_error_string(
                'Underlying buying suspended between NY1600 and GMT0000',
                symbol   => $self->underlying->symbol,
                duration => $self->remaining_time->as_concise_string
            ),
            message_to_client => $message . ' ',
            info_link         => request()->url_for('/resources/asset_indexws'),
            info_text         => localize('View Asset Index'),
            };
    }

    return @errors;
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
    my @validation_methods =
        qw(_validate_lifetime  _validate_volsurface _validate_contract _validate_barrier _validate_underlying _validate_expiry_date _validate_start_date _validate_stake _validate_payout _validate_eod_market_risk);

    foreach my $method (@validation_methods) {
        my @err = $self->$method;
        $self->add_error($err[0]) if @err;
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

# Don't mind me, I just need to make sure my attibutes are available.
with 'BOM::Product::Role::Reportable';

no Moose;

__PACKAGE__->meta->make_immutable;

1;
