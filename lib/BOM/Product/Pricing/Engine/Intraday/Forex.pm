package BOM::Product::Pricing::Engine::Intraday::Forex;

use Moose;
extends 'BOM::Product::Pricing::Engine';
with 'BOM::Product::Pricing::Engine::Role::RiskMarkup';

use List::Util qw(max min sum first);
use List::MoreUtils qw(any);
use Array::Utils qw(:all);

use BOM::Market::DataDecimate;
use Volatility::Seasonality;
use VolSurface::Utils qw( get_delta_for_strike );
use Math::Function::Interpolator;
use Finance::Exchange;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use Pricing::Engine::BlackScholes;
use Pricing::Engine::Markup::EconomicEventsSpotRisk;
use Pricing::Engine::Markup::EqualTie;
use Pricing::Engine::Markup::CustomCommission;
use Pricing::Engine::Markup::HourEndMarkup;
use Pricing::Engine::Markup::HourEndDiscount;
use Pricing::Engine::Markup::IntradayMeanReversionMarkup;
use Pricing::Engine::Markup::RollOverMarkup;
use Pricing::Engine::Markup::IntradayForexRisk;
use Pricing::Engine::Markup::ModelArbitrage;
use Math::Util::CalculatedValue::Validatable;
use Math::Business::BlackScholes::Binaries::Greeks::Vega;

=head2 POTENTIAL_ARBITRAGE_DURATION

Intraday switches model when duration exceeds 5 hours. This markup applies to contract with duration more than or equal to 4h59m.

=cut

use constant POTENTIAL_ARBITRAGE_DURATION => 17940;
use constant HISTORICAL_VOL_MEANREV       => 0.10;

=head2 tick_source

The source of the ticks used for this pricing. 

=cut

has tick_source => (
    is      => 'ro',
    default => sub {
        BOM::Market::DataDecimate->new({market => 'forex'});
    },
);

has custom_commission => (
    is      => 'ro',
    default => sub { [] },
);

has inefficient_period => (
    is      => 'ro',
    default => 0,
);

has economic_events => (
    is => 'ro',
);

has long_term_prediction => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_long_term_prediction {
    return Math::Util::CalculatedValue::Validatable->new({
            name        => 'long_term_prediction',
            description => 'long term prediction for intraday historical model',
            set_by      => __PACKAGE__,
            base_amount => shift->bet->_pricing_args->{long_term_prediction}});
}

has _supported_types => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        return {
            CALL     => 1,
            PUT      => 1,
            ONETOUCH => 1,
            NOTOUCH  => 1,
        };
    },
);

has [qw(base_probability probability long_term_prediction intraday_vanilla_delta risk_markup)] => (
    is         => 'ro',
    lazy_build => 1,
);

has apply_equal_tie_markup => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_apply_equal_tie_markup {
    my $self = shift;
    return ((
                   $self->bet->code eq 'CALLE'
                or $self->bet->code eq 'PUTE'
        )
            and ($self->bet->underlying->submarket->name eq 'major_pairs' or $self->bet->underlying->submarket->name eq 'minor_pairs')) ? 1 : 0;
}

sub _build_base_probability {
    my $self         = shift;
    my $pricing_args = $self->bet->_pricing_args;

    my $blackscholes = Pricing::Engine::BlackScholes->new(
        strikes         => [$pricing_args->{barrier1}],
        spot            => $pricing_args->{spot},
        discount_rate   => 0,
        t               => $pricing_args->{t},
        mu              => 0,
        vol             => $pricing_args->{iv},
        payouttime_code => $pricing_args->{payouttime_code},
        payout_type     => 'binary',
        contract_type   => $self->bet->pricing_code,
    );

    my $base_probability = Math::Util::CalculatedValue::Validatable->new({
        name        => 'base_probability',
        description => 'BS pricing based on realized vols',
        set_by      => __PACKAGE__,
        base_amount => $blackscholes->theo_probability,
        minimum     => 0,
    });

    $base_probability->include_adjustment('add', $self->_intraday_vega_correction);

    return $base_probability;
}

=head1 probability

The final theoretical probability after corrections.  Math::Util::CalculatedValue::Validatable

=cut

sub _build_probability {
    my ($self) = @_;

    my $bet = $self->bet;

    my $ifx_prob = Math::Util::CalculatedValue::Validatable->new({
        name        => lc($bet->code) . '_theoretical_probability',
        description => 'BS pricing based on realized vols',
        set_by      => __PACKAGE__,
        minimum     => 0,
        maximum     => 1,
    });

    $ifx_prob->include_adjustment('reset', $self->base_probability);
    $ifx_prob->include_adjustment('add',   $self->risk_markup);

    return $ifx_prob;
}

sub economic_events_markup {
    my $self = shift;
    my $markup;

    $markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'economic_events_markup',
        description => 'the maximum of spot or volatility risk markup of economic events',
        set_by      => __PACKAGE__,
        base_amount => max($self->event_markup->amount, $self->economic_events_spot_risk_markup->amount),
    });

    $markup->include_adjustment('info', $self->event_markup);
    $markup->include_adjustment('info', $self->economic_events_spot_risk_markup);

    return $markup;
}

has ticks_for_trend => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_ticks_for_trend {
    my $self = shift;

    my $bet              = $self->bet;
    my $duration_in_secs = $bet->timeindays->amount * 86400;
    my $lookback_secs    = $duration_in_secs * 2;              # lookback twice the duration

    my $remaining_interval = Time::Duration::Concise::Localize->new(interval => $lookback_secs);

    my $ticks;
    my $backprice = ($bet->underlying->for_date) ? 1 : 0;
    $ticks = $self->tick_source->get({
        underlying  => $bet->underlying,
        start_epoch => $bet->date_pricing->epoch - $remaining_interval->seconds,
        end_epoch   => $bet->date_pricing->epoch,
        backprice   => $backprice,
        decimate    => $self->more_than_short_term_cutoff,
    });

    return $ticks;
}

has more_than_short_term_cutoff => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_more_than_short_term_cutoff {
    my $self = shift;

    return ($self->bet->get_time_to_expiry->minutes >= 15) ? 1 : 0;
}

=head1 intraday_vanilla_delta

The delta for a vanilla call with the same parameters as this bet.

=cut

sub _build_intraday_vanilla_delta {
    my $self = shift;

    my $bet           = $self->bet;
    my $args          = $bet->_pricing_args;
    my $barrier_delta = get_delta_for_strike({
        strike           => $args->{barrier1},
        atm_vol          => $args->{iv},
        spot             => $args->{spot},
        t                => $bet->timeinyears->amount,
        r_rate           => 0,
        q_rate           => 0,
        premium_adjusted => $bet->underlying->market_convention->{delta_premium_adjusted},
    });

    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'intraday_vanilla_delta',
        description => 'The delta of a vanilla call with the same parameters as this bet',
        set_by      => __PACKAGE__,
        base_amount => $barrier_delta,
    });
}

my $iv_risk_interpolator = Math::Function::Interpolator->new(
    points => {
        0.05 => 0.30,
        0.5  => 0,
        0.95 => 0.30,
    });

my $shortterm_risk_interpolator = Math::Function::Interpolator->new(
    points => {
        0  => 0.15,
        15 => 0,
    });

sub apply_mean_reversion_markup {
    my $self = shift;

    my $bet          = $self->bet;
    my $bet_duration = $bet->timeindays->amount * 24 * 60;
    # Maximum lookback period is 30 minutes
    my $lookback_duration = min(30, $bet_duration);
    #  We did not do any ajdusment if there is nothing to lookback ie either monday morning or the next day after early close
    return $bet->trading_calendar->is_open_at($bet->underlying->exchange, $bet->date_start->minus_time_interval($lookback_duration . 'm'));
}

sub apply_quiet_period_markup {
    my $self = shift;

    my $bet = $self->bet;
    my $apply_flag =
        ($bet->trading_calendar->is_open_at($bet->underlying->exchange, $bet->date_start) and $bet->is_in_quiet_period($bet->date_pricing))
        ? 1
        : 0;

    return $apply_flag;
}

=head1 risk_markup

Markup added to accommdate for pricing uncertainty

=cut

sub _build_risk_markup {
    my $self = shift;

    my $bet          = $self->bet;
    my $bet_duration = $bet->timeindays->amount * 24 * 60;
    # Maximum lookback period is 30 minutes
    my $lookback_duration = min(30, $bet_duration);

    my $min_max         = $bet->spot_min_max($bet->date_start->minus_time_interval($lookback_duration . 'm'));
    my $rollover_hour   = $bet->underlying->market->name eq 'forex' ? $bet->volsurface->rollover_date($bet->date_pricing) : undef;
    my $apply_equal_tie = $self->apply_equal_tie_markup;

    my $mean_reversion_markup = (defined $self->apply_mean_reversion_markup and $self->apply_mean_reversion_markup) ? 1 : 0;

    my %markup_params = (
        apply_mean_reversion_markup => $mean_reversion_markup,
        min_max                     => $min_max,
        custom_commission           => $bet->_custom_commission,
        effective_start             => $bet->effective_start,
        date_expiry                 => $bet->date_expiry,
        barrier_tier                => $bet->barrier_tier,
        symbol                      => $bet->underlying->symbol,
        economic_events             => $bet->economic_events_for_volatility_calculation,
        apply_quiet_period_markup   => $self->apply_quiet_period_markup,
        #payout                      => $bet->payout,
        apply_rollover_markup      => $bet->apply_rollover_markup,
        rollover_date              => $rollover_hour,
        interest_rate_difference   => $bet->q_rate - $bet->r_rate,
        date_start                 => $bet->date_start,
        market                     => $bet->underlying->market->name,
        market_is_inefficient      => $bet->market_is_inefficient,
        contract_category          => $bet->category->code,
        hour_end_markup_parameters => $bet->hour_end_markup_parameters,
        enable_hour_end_discount   => BOM::Config::Runtime->instance->app_config->quants->enable_hour_end_discount,
        apply_equal_tie_markup     => $apply_equal_tie,
        spot                       => $bet->pricing_spot,
        contract_type              => $bet->pricing_code,
        t                          => $bet->timeinyears->amount,

        inefficient_period     => $bet->market_is_inefficient,
        long_term_average_vol  => $self->long_term_average_vol,
        iv                     => $bet->_pricing_args->{iv},
        intraday_vega          => $self->base_probability->peek_amount('intraday_vega'),
        remaining_time         => $bet->remaining_time->minutes,
        is_path_dependent      => $bet->is_path_dependent,
        intraday_vanilla_delta => $self->intraday_vanilla_delta->amount,
        is_atm_bet             => $bet->is_atm_bet,
        is_forward_starting    => $bet->is_forward_starting,
        bs_probability         => $self->base_probability->base_amount,
    );

    my $risk_markup = Pricing::Engine::Markup::IntradayForexRisk->new(%markup_params)->markup;

    my $contract_duration = $bet->date_expiry->epoch - $bet->date_start->epoch;
    if ($bet->pricing_new and $contract_duration >= POTENTIAL_ARBITRAGE_DURATION) {
        $risk_markup->include_adjustment('add', Pricing::Engine::Markup::ModelArbitrage->new->markup);
    }

    return $risk_markup;
}

sub event_markup {
    my $self = shift;

    return Pricing::Engine::Markup::CustomCommission->new(
        custom_commission => $self->custom_commission,
        effective_start   => $self->bet->effective_start,
        date_expiry       => $self->bet->date_expiry,
        base_probability  => $self->base_probability->amount,
        barrier_tier      => $self->bet->barrier_tier,
    )->markup;
}

sub economic_events_spot_risk_markup {
    my $self = shift;

    my $bet = $self->bet;
    return Pricing::Engine::Markup::EconomicEventsSpotRisk->new(
        effective_start   => $bet->effective_start,
        date_expiry       => $bet->date_expiry,
        economic_events   => $self->economic_events,
        underlying_symbol => $bet->underlying->symbol,
    )->markup;
}

sub long_term_average_vol {
    my $self = shift;

    return ($self->bet->is_in_quiet_period($self->bet->date_pricing)) ? 0.035 : 0.07;
}

sub vol_spread_markup {
    my $self = shift;

    my $bet = $self->bet;

    my $long_term_average_vol = $self->long_term_average_vol;
    # We cap vol spread at +/-5%
    my $vol_spread = min(0.05, max(-0.05, $long_term_average_vol - $bet->_pricing_args->{iv}));
    my $vega       = $self->base_probability->peek_amount('intraday_vega');
    my $multiplier = $vega < 0 ? 1 : 0.5;

    return Pricing::Engine::Markup::VolSpread->new(
        bet_vega   => $vega,
        vol_spread => $vol_spread,
        multiplier => $multiplier,
    )->markup;
}

sub get_compatible {
    my ($class, $to_load, $metadata) = @_;

    return BOM::Product::Pricing::Engine->is_compatible($to_load, $metadata) ? $class : undef;
}

has [qw(_intraday_vega_correction _intraday_vega)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__intraday_vega {
    my $self = shift;

    my $formula = "Math::Business::BlackScholes::Binaries::Greeks::Vega"->can(lc $self->bet->pricing_code)
        or die "Vega has no method for " . $self->bet->pricing_code;

    my $pricing_args = $self->bet->_pricing_args;
    my $formula_args = [
        $pricing_args->{spot},
        $pricing_args->{barrier1},
        $pricing_args->{t},
        0,    # discount_rate
        0,    # mu
        $pricing_args->{iv},
        $pricing_args->{payouttime_code}];
    my $v = Math::Util::CalculatedValue::Validatable->new({
        name        => 'intraday_vega',
        description => "the vega to use for pricing this bet",
        set_by      => __PACKAGE__,
        base_amount => $formula->(@{$formula_args}),
    });

    return $v;
}

sub _build__intraday_vega_correction {
    my $self = shift;

    my $vc = Math::Util::CalculatedValue::Validatable->new({
        name        => 'intraday_vega_correction',
        description => 'correction for uncertainty of vol',
        set_by      => __PACKAGE__,
        base_amount => HISTORICAL_VOL_MEANREV,
    });

    $vc->include_adjustment('multiply', $self->_intraday_vega);
    $vc->include_adjustment('multiply', $self->long_term_prediction);
    return $vc;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
