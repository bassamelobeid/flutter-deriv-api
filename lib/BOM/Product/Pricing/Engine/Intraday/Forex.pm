package BOM::Product::Pricing::Engine::Intraday::Forex;

use Moose;
extends 'BOM::Product::Pricing::Engine';
with 'BOM::Product::Pricing::Engine::Role::StandardMarkup';

use List::Util qw(max min sum first);
use Array::Utils qw(:all);

use BOM::Market::DataDecimate;
use Volatility::Seasonality;
use VolSurface::Utils qw( get_delta_for_strike );
use Math::Function::Interpolator;
use Pricing::Engine::Intraday::Forex::Base;

=head2 tick_source

The source of the ticks used for this pricing. 

=cut

has tick_source => (
    is      => 'ro',
    default => sub {
        BOM::Market::DataDecimate->new;
    },
);

has inefficient_period => (
    is      => 'ro',
    default => 0,
);

has economic_events => (
    is       => 'ro',
    required => 1,
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

has [
    qw(base_probability probability long_term_prediction economic_events_markup intraday_vanilla_delta risk_markup)
    ] => (
    is         => 'ro',
    lazy_build => 1,
    );

sub _build_base_probability {
    my $self = shift;

    my $bet          = $self->bet;
    my $pricing_args = $bet->_pricing_args;

    my %args = (
        ticks                => $self->ticks_for_trend,
        strikes              => [$pricing_args->{barrier1}],
        vol                  => $pricing_args->{iv},
        contract_type        => $bet->pricing_code,
        payout_type          => 'binary',
        underlying_symbol    => $bet->underlying->symbol,
        long_term_prediction => $self->long_term_prediction->amount,
        discount_rate        => 0,
        mu                   => 0,
        (map { $_ => $pricing_args->{$_} } qw(spot t payouttime_code)));

    my $engine = Pricing::Engine::Intraday::Forex::Base->new(%args,);
    return $engine->base_probability;
}

=head1 probability

The final theoretical probability after corrections.  Math::Util::CalculatedValue::Validatable

=cut

sub _build_probability {
    my ($self) = @_;

    my $bet  = $self->bet;
    my $args = $bet->_pricing_args;

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

sub _build_economic_events_markup {
    my $self = shift;
    my $bet  = $self->bet;
    my $markup;

    $markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'economic_events_markup',
        description => 'the maximum of spot or volatility risk markup of economic events',
        set_by      => __PACKAGE__,
        base_amount => max($self->economic_events_volatility_risk_markup->amount, $self->economic_events_spot_risk_markup->amount),
    });

    $markup->include_adjustment('info', $self->economic_events_volatility_risk_markup);
    $markup->include_adjustment('info', $self->economic_events_spot_risk_markup);

    return $markup;
}

=head2 _tentative_events_markup

As part of the Japanese regulatory requirement, we are required to provide bid and ask prices at all times during 
trading hours. One of our backoffice controls, namely the tentative blackout period tool which stops sales of 
**non-ATM** intraday contracts spanning a tentative period does not to fulfill this requirement. 

This branch aims to the generalise the blackout period tool, by introducing a new measure called ‘expected returns’ 
to control the range of option prices (of all types) across strike/barrier prices. 

For an x% expected return input, all **non-ATM** intraday contracts (< 5 hours) spanning a tentative period are re-priced as follow:
 
-   Binary calls at strike prices K will be priced as binary calls at strike prices K*(1-x%)
 
-   Binary puts at strike prices K will be priced as binary puts at strike prices K*(1+x%)
 
-   Touch options with upper barriers K will be priced as touch options with upper barriers K*(1-x%)

-   Touch options with lower barriers K will be priced as touch options with lower barriers K*(1+x%)
 
-   No-touch options with upper barriers K will be priced as no-touch options with upper barrier K*(1+x%)
 
-   No-touch options with lower barriers K will be priced as no-touch options with lower barriers K*(1-x%)

Note: The tool does not affect intraday **ATM** contracts.

=cut

sub _tentative_events_markup {
    my $self = shift;
    my $bet  = $self->bet;

    #Don't calculate tentative event shfit if contract is ATM
    #In this case, economic events markup will be calculated using normal formula
    if ($bet->is_atm_bet) {
        return Math::Util::CalculatedValue::Validatable->new({
            name        => 'economic_events_volatility_risk_markup',
            description => 'markup to account for volatility risk of economic events',
            set_by      => __PACKAGE__,
            base_amount => 0,
        });
    }

    my $barrier          = $bet->barrier->as_absolute;
    my $adjusted_barrier = $self->_get_barrier_for_tentative_events($barrier);

    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'economic_events_volatility_risk_markup',
        description => 'markup to account for volatility risk of economic events',
        set_by      => __PACKAGE__,
        base_amount => 0,
    }) if $barrier == $adjusted_barrier;

    # There is a change needed in the barriers due to tentative events:
    my $type = $bet->code;
    #For one-touch and no-touch, If barrier crosses the spot because of our barrier adjustments, just make sure prob will be 100%
    if ($type eq 'ONETOUCH' or $type eq 'NOTOUCH') {
        if (   ($barrier < $bet->pricing_spot and $adjusted_barrier >= $bet->pricing_spot)
            or ($barrier > $bet->pricing_spot and $adjusted_barrier <= $bet->pricing_spot))
        {
            return Math::Util::CalculatedValue::Validatable->new({
                name        => 'economic_events_volatility_risk_markup',
                description => 'markup to account for volatility risk of economic events',
                set_by      => __PACKAGE__,
                base_amount => 1.0,
            });
        }
    }

    my %args = (map { $_ => $bet->_pricing_args->{$_} } qw(spot t payouttime_code));

    my $vol    = $bet->_pricing_args->{iv};
    my $engine = Pricing::Engine::Intraday::Forex::Base->new(
        ticks                => $self->ticks_for_trend,
        strikes              => [$adjusted_barrier],
        vol                  => $vol,
        contract_type        => $bet->pricing_code,
        payout_type          => 'binary',
        underlying_symbol    => $bet->underlying->symbol,
        long_term_prediction => $self->long_term_prediction->amount,
        discount_rate        => 0,
        mu                   => 0,
        %args,
    );
    my $new_prob = $engine->base_probability;

    $new_prob = $new_prob->amount if Scalar::Util::blessed($new_prob) && $new_prob->isa('Math::Util::CalculatedValue::Validatable');

    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'economic_events_volatility_risk_markup',
        description => 'markup to account for volatility risk of economic events',
        set_by      => __PACKAGE__,
        base_amount => max(0, $new_prob - $self->base_probability->amount),
    });
}

sub _get_barrier_for_tentative_events {
    my $self    = shift;
    my $barrier = shift;

    my $bet = $self->bet;

    #When pricing options during the news event period, the tentative event  shifts the strikes/barriers so that prices are marked up. Here are examples for each contract type:
    #A binary call strike = 105 and an tentative event  of 2% will be priced as a binary call strike = 105/(1+2%)
    #A binary put strike = 105 and an tentative event shift of 2% will be priced as a binary put strike = 105*(1+2%)
    #A touch (upper) barrier = 105 and an tentative event shift of 2% will be priced as a touch barrier = 105/(1+2%)
    #A touch (lower) barrier = 105 and an tentative event shift of 2% will be priced as a touch barrier = 105*(1+2%)
    #A no-touch (upper) barrier = 105 and an tentative event shift of 2% will be priced as a no-touch barrier = 105*(1+2%)
    #A no-touch (lower) barrier = 105 and an tentative event shift of 2% will be priced as a no-touch barrier = 105/(1+2%)
    #get a list of applicable tentative economic events
    my $tentative_events = $bet->tentative_events;

    my $tentative_event_shift = 0;

    foreach my $event (@{$tentative_events}) {
        my $shift = $event->{tentative_event_shift} // 0;

        #We add-up all tentative event shfit  applicable for any of symbols of the currency pair
        if ($event->{symbol} eq $bet->underlying->asset_symbol) {
            $tentative_event_shift += $shift;
        } elsif ($event->{symbol} eq $bet->underlying->quoted_currency_symbol) {
            $tentative_event_shift += $shift;
        }
    }

    #quickly return if there is no shift
    return $barrier if $tentative_event_shift == 0;

    $tentative_event_shift /= 100;

    my $er_factor = 1 + $tentative_event_shift;
    my $barrier_u = $barrier >= $bet->pricing_spot;
    my $barrier_d = $barrier <= $bet->pricing_spot;
    my $type      = $bet->code;

    #final barrier is either "Barrier * (1+ER)" or "Barrier * (1-ER)"
    if ((
               $type eq 'CALL'
            or $type eq 'CALLE'
        )
        or ($type eq 'ONETOUCH'     && $barrier_u)
        or ($type eq 'NOTOUCH'      && $barrier_d)
        or ($type eq 'EXPIRYRANGE'  && $barrier_u)
        or ($type eq 'EXPIRYRANGEE' && $barrier_u)
        or ($type eq 'EXPIRYMISS'   && $barrier_d)
        or ($type eq 'EXPIRYMISSE'  && $barrier_d)
        or ($type eq 'RANGE'        && $barrier_d)
        or ($type eq 'UPORDOWN'     && $barrier_u))
    {

        $er_factor = 1 - $tentative_event_shift;
    }

    $barrier *= $er_factor;

    return $barrier;
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
    my $period_start     = $bet->date_pricing->epoch;

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
        0.05 => 0.15,
        0.5  => 0,
        0.95 => 0.15,
    });

my $shortterm_risk_interpolator = Math::Function::Interpolator->new(
    points => {
        0  => 0.15,
        15 => 0,
    });

=head1 risk_markup

Markup added to accommdate for pricing uncertainty

=cut

sub _build_risk_markup {
    my $self = shift;

    my $bet         = $self->bet;
    my $risk_markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'risk_markup',
        description => 'A set of markups added to accommodate for pricing risk',
        set_by      => __PACKAGE__,
        minimum     => 0,
        base_amount => 0,
    });

    $risk_markup->include_adjustment('add', $self->economic_events_markup);

    if ($bet->is_path_dependent) {
        my $iv_risk = Math::Util::CalculatedValue::Validatable->new({
            name        => 'intraday_historical_iv_risk',
            description => 'Intraday::Forex markup for IV contracts only.',
            set_by      => __PACKAGE__,
            base_amount => $iv_risk_interpolator->linear($self->intraday_vanilla_delta->amount),
        });
        $risk_markup->include_adjustment('add', $iv_risk);
    }

    if ($bet->underlying->calendar->is_open_at($bet->date_start) and $bet->underlying->is_in_quiet_period($bet->date_pricing)) {
        my $quiet_period_markup = Math::Util::CalculatedValue::Validatable->new({
            name        => 'quiet_period_markup',
            description => 'Intraday::Forex markup factor for underlyings in the quiet period',
            set_by      => __PACKAGE__,
            base_amount => 0.01,
        });
        $risk_markup->include_adjustment('add', $quiet_period_markup);
    }

    if ($bet->market->name eq 'commodities') {
        my $illiquid_market_markup = Math::Util::CalculatedValue::Validatable->new({
            name        => 'illiquid_market_markup',
            description => 'Intraday::Forex markup factor for commodities',
            set_by      => __PACKAGE__,
            base_amount => 0.015,
        });
        $risk_markup->include_adjustment('add', $illiquid_market_markup);
    }

    if($bet->is_atm_bet) {
        $risk_markup->include_adjustment('add', Math::Util::CalculatedValue::Validatable->new({
            name        => 'intraday_eod_markup',
            description => '5% markup for inefficient period',
            set_by      => __PACKAGE__,
            base_amount => 0.05,
        })) if $self->inefficient_period
    } else {
        $risk_markup->include_adjustment('add', $self->vol_spread_markup);
        $risk_markup->include_adjustment('add', Math::Util::CalculatedValue::Validatable->new({
            name        => 'intraday_eod_markup',
            description => '10% markup for inefficient period',
            set_by      => __PACKAGE__,
            base_amount => 0.1,
        })) if $self->inefficient_period;
        $risk_markup->include_adjustment('add', Math::Util::CalculatedValue::Validatable->new({
            name        => 'short_term_kurtosis_risk_markup',
            description => 'shortterm markup added for kurtosis risk for contract less than 15 minutes',
            set_by      => __PACKAGE__,
            base_amount => $shortterm_risk_interpolator->linear($bet->remaining_time->minutes),
        })) if $bet->remaining_time->minutes <= 15;
    }

    return $risk_markup;
}

has [qw(economic_events_volatility_risk_markup economic_events_spot_risk_markup)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_economic_events_volatility_risk_markup {
    my $self = shift;

    # Tentative event markup takes precedence
    if((my $tentative_events_markup = $self->_tentative_events_markup)->amount) {
        return $tentative_events_markup;
    }

    my $markup_base_amount = 0;

    # since we are parsing in both vols now, we just check for difference in vol to determine if there's a markup
    my $pricing_args              = $self->bet->_pricing_args;
    my $news_adjusted_pricing_vol = $pricing_args->{iv_with_news};
    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'economic_events_volatility_risk_markup',
        description => 'markup to account for volatility risk of economic events',
        set_by      => __PACKAGE__,
        base_amount => 0,
    }) if $pricing_args->{iv} == $news_adjusted_pricing_vol;

    # Otherwise, we fall back to news-adjusted probability
    my $tv_without_news = $self->base_probability->amount;

    # Re-calculate  base probability using the news_adjusted_pricing_vol

    my %args = (map { $_ => $pricing_args->{$_} } qw(spot t payouttime_code));

    my $engine = Pricing::Engine::Intraday::Forex::Base->new(
        ticks                => $self->ticks_for_trend,
        strikes              => [$pricing_args->{barrier1}],
        vol                  => $news_adjusted_pricing_vol,
        contract_type        => $self->bet->pricing_code,
        payout_type          => 'binary',
        underlying_symbol    => $self->bet->underlying->symbol,
        long_term_prediction => $self->long_term_prediction->amount,
        discount_rate        => 0,
        mu                   => 0,
        %args,
    );
    my $tv_with_news = $engine->base_probability->amount;

    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'economic_events_volatility_risk_markup',
        description => 'markup to account for volatility risk of economic events',
        set_by      => __PACKAGE__,
        base_amount => max(0, $tv_with_news - $tv_without_news),
    });
}

sub _build_economic_events_spot_risk_markup {
    my $self = shift;

    my $bet   = $self->bet;
    my $start = $bet->effective_start;
    my $end   = $bet->date_expiry;
    my @time_samples;
    for (my $i = $start->epoch; $i <= $end->epoch; $i += 15) {
        push @time_samples, $i;
    }

    my $contract_duration = $bet->remaining_time->seconds;
    my $lookback          = $start->minus_time_interval($contract_duration + 3600);
    my $news_array        = $self->_get_economic_events;

    my @combined = (0) x scalar(@time_samples);
    foreach my $news (@$news_array) {
        my $effective_news_time = _get_effective_news_time($news->{release_epoch}, $start->epoch, $contract_duration);
        # +1e-9 is added to prevent a division by zero error if news magnitude is 1
        my $decay_coef = -log(2 / ($news->{magnitude} + 1e-9)) / $news->{duration};
        my $bias = $news->{bias};
        my @triangle;
        foreach my $time (@time_samples) {
            if ($time < $effective_news_time) {
                push @triangle, 0;
            } else {
                my $chunk = $bias * exp(-$decay_coef * ($time - $effective_news_time));
                push @triangle, $chunk;
            }
        }
        @combined = map { max($triangle[$_], $combined[$_]) } (0 .. $#time_samples);
    }

    my $spot_risk_markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'economic_events_spot_risk_markup',
        description => 'markup to account for spot risk of economic events',
        set_by      => __PACKAGE__,
        maximum     => 0.15,
        base_amount => sum(@combined) / scalar(@combined),
    });

    return $spot_risk_markup;
}

sub _get_economic_events {
    my ($self) = @_;

    my $qfs = Volatility::Seasonality->new;
    my $events = $qfs->categorize_events($self->bet->underlying->symbol, $self->economic_events);

    return $events;
}

sub _get_effective_news_time {
    my ($news_time, $contract_start, $contract_duration) = @_;

    my $five_minutes_in_seconds = 5 * 60;
    my $shift_seconds           = 0;
    my $contract_end            = $contract_start + $contract_duration;
    if ($news_time > $contract_start - $five_minutes_in_seconds and $news_time < $contract_start) {
        $shift_seconds = $contract_start - $news_time;
    } elsif ($news_time < $contract_end + $five_minutes_in_seconds and $news_time > $contract_end - $five_minutes_in_seconds) {
        # Always shifts to the contract start time if duration is less than 5 minutes.
        my $max_shift = min($five_minutes_in_seconds, $contract_duration);
        my $desired_start = $contract_end - $max_shift;
        $shift_seconds = $desired_start - $news_time;
    }

    my $effective_time = $news_time + $shift_seconds;

    return $effective_time;
}

sub volatility_scaling_factor {
    return shift->bet->_pricing_args->{volatility_scaling_factor};
}

has vol_spread => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_vol_spread',
);

sub _build_vol_spread {
    my $self = shift;

    my $vol_spread = Math::Util::CalculatedValue::Validatable->new({
        name        => 'vol_spread',
        set_by      => __PACKAGE__,
        description => 'markup added to account for variable ticks interval for volatility calculation.',
        minimum     => 0,
        maximum     => 0.1,
        base_amount => (0.1 * (1 - ($self->volatility_scaling_factor)**2)) / 2,
    });

    return $vol_spread;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
