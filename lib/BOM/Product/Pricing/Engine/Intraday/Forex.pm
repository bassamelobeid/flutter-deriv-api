package BOM::Product::Pricing::Engine::Intraday::Forex;

use Moose;
extends 'BOM::Product::Pricing::Engine::Intraday';

use List::Util qw(max min sum);
use YAML::XS qw(LoadFile);

use Math::Business::BlackScholes::Binaries::Greeks::Delta;
use Math::Business::BlackScholes::Binaries::Greeks::Vega;
use VolSurface::Utils qw( get_delta_for_strike );
use Math::Function::Interpolator;
use BOM::System::Config;

sub clone {
    my ($self, $changes) = @_;
    return $self->new({
        bet => $self->bet,
        %$changes
    });
}

my $coefficient = LoadFile('/home/git/regentmarkets/bom/config/files/intraday_trend_calibration.yml');

has coefficients => (
    is      => 'ro',
    default => sub { $coefficient },
);

has [qw(long_term_prediction)] => (
    is         => 'ro',
    lazy_build => 1,
);

has apply_bounceback_safety => (
    is      => 'ro',
    default => undef,
);

has [qw(pricing_vol news_adjusted_pricing_vol)] => (
    is         => 'rw',
    lazy_build => 1,
);

sub _build_news_adjusted_pricing_vol {
    return shift->bet->pricing_args->{iv_with_news};
}

sub _build_long_term_prediction {
    return Math::Util::CalculatedValue::Validatable->new({
            name        => 'long_term_prediction',
            description => 'long term prediction for intraday historical model',
            set_by      => __PACKAGE__,
            base_amount => shift->bet->pricing_args->{long_term_prediction}});
}

sub _build_pricing_vol {
    return shift->bet->pricing_args->{iv};
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
    qw(base_probability probability intraday_delta_correction short_term_prediction long_term_prediction economic_events_markup intraday_trend intraday_vanilla_delta risk_markup)
    ] => (
    is         => 'ro',
    lazy_build => 1,
    );

## PRIVATE ##
has [qw(_delta_formula _vega_formula)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_base_probability {
    my $self = shift;

    my $base_probability = Math::Util::CalculatedValue::Validatable->new({
        name        => 'base_probability',
        description => 'BS pricing based on realized vols',
        set_by      => __PACKAGE__,
        base_amount => $self->formula->($self->_formula_args),
        minimum     => 0,
    });

    $base_probability->include_adjustment('add', $self->intraday_delta_correction);
    $base_probability->include_adjustment('add', $self->intraday_vega_correction);

    return $base_probability;
}

=head1 probability

The final theoretical probability after corrections.  Math::Util::CalculatedValue::Validatable

=cut

sub _build_probability {
    my ($self) = @_;

    my $bet  = $self->bet;
    my $args = $bet->pricing_args;

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

sub _build__delta_formula {
    my $self = shift;

    my $formula_name = 'Math::Business::BlackScholes::Binaries::Greeks::Delta::' . lc $self->bet->pricing_code;

    return \&$formula_name;
}

=head1 intraday_delta

The delta of this option, given our inputs.  Math::Util::CalculatedValue::Validatable

=cut

sub _build_intraday_delta {
    my $self = shift;

    my $idd = Math::Util::CalculatedValue::Validatable->new({
        name        => 'intraday_delta',
        description => 'the delta to use for pricing this bet',
        set_by      => __PACKAGE__,
        base_amount => $self->_delta_formula->($self->_formula_args),
    });

    return $idd;
}

sub _build__vega_formula {
    my $self = shift;

    my $formula_name = 'Math::Business::BlackScholes::Binaries::Greeks::Vega::' . lc $self->bet->pricing_code;

    return \&$formula_name;
}

=head1 intraday_vega

The vega of this option given our computed inputs.  Math::Util::CalculatedValue::Validatable

=cut

sub _build_intraday_vega {
    my $self = shift;

    my $bet = $self->bet;

    my $idv = Math::Util::CalculatedValue::Validatable->new({
        name        => 'intraday_vega',
        description => 'the delta to use for pricing this bet',
        set_by      => __PACKAGE__,
        base_amount => $self->_vega_formula->($self->_formula_args),
    });

    return $idv;
}

sub _build_economic_events_markup {
    my $self = shift;

    my $markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'economic_events_markup',
        description => 'the maximum of spot or volatility risk markup of economic events',
        set_by      => __PACKAGE__,
        base_amount => max($self->economic_events_volatility_risk_markup->amount, $self->economic_events_spot_risk_markup->amount),
    });

    $markup->include_adjustment('info', $self->economic_events_volatility_risk_markup);
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
    my $lookback_secs    = $duration_in_secs * 2;              # lookback twice the duratiom
    my $period_start     = $bet->date_pricing->epoch;

    my $remaining_interval = Time::Duration::Concise::Localize->new(interval => $lookback_secs);

    return $self->tick_source->retrieve({
        underlying   => $bet->underlying,
        interval     => $remaining_interval,
        ending_epoch => $bet->date_pricing->epoch,
        fill_cache   => !$bet->backtest,
        aggregated   => $self->more_than_short_term_cutoff,
    });
}

has lookback_seconds => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_lookback_seconds {
    my $self             = shift;
    my @ticks            = @{$self->ticks_for_trend};
    my $duration_in_secs = $self->bet->timeindays->amount * 86400;
    my $lookback_secs    = 0;

    $lookback_secs = $ticks[-1]->{epoch} - $ticks[0]->{epoch} if scalar(@ticks) > 1;

    # If gotten lookback ticks period is lower then 80% of duration*2
    # that means we have not enought ticks to make price
    # we should use gotten lookback period to correct probability
    my $ticks_per_sec = $lookback_secs / 2 / $duration_in_secs;
    if ($ticks_per_sec <= 0.8) {
        return $lookback_secs;
    }
    return $duration_in_secs * 2;
}

has slope => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_slope {
    my $self             = shift;
    my $duration_in_secs = $self->bet->timeindays->amount * 86400;

    my $ticks_per_sec = $self->lookback_seconds / $duration_in_secs;
    return (sqrt(1 - (($ticks_per_sec - 2)**2) / 4));
}

=head1 intraday_trend

ASSUMPTIONS: If there's no ticks to calculate trend, we will assume there's no trend. But we will not sell since volatility calculation (which uses the same set of ticks), will fail.

The current observed trend in the market movements.  Math::Util::CalculatedValue::Validatable

=cut

sub _build_intraday_trend {
    my $self = shift;

    my $bet              = $self->bet;
    my $duration_in_secs = $bet->timeindays->amount * 86400;

    my @ticks    = @{$self->ticks_for_trend};
    my $average  = (@ticks) ? sum(map { $_->{quote} } @ticks) / @ticks : $bet->pricing_args->{spot};
    my $avg_spot = Math::Util::CalculatedValue::Validatable->new({
        name        => 'average_spot',
        description => 'mean of spot over 2 * duration of the contract',
        set_by      => __PACKAGE__,
        base_amount => $average,
    });

    my $trend = 0;
    # Lookback seconds is only set to zero if @ticks has less than or equal to one element.
    # But let's be extra careful here.
    my $lookback_seconds = $self->lookback_seconds;
    if (@ticks > 1 and $lookback_seconds > 0) {
        $trend = ((($bet->pricing_args->{spot} - $avg_spot->amount) / $avg_spot->amount) / sqrt($lookback_seconds / 2)) * $self->slope;
    }
    my $calibration_coef = $self->coefficients->{$bet->underlying->symbol};
    my $trend_cv         = Math::Util::CalculatedValue::Validatable->new({
        name        => 'intraday_trend',
        description => 'Intraday trend based on historical data',
        minimum     => $calibration_coef->{trend_min} * $self->slope,
        maximum     => $calibration_coef->{trend_max} * $self->slope,
        set_by      => __PACKAGE__,
        base_amount => $trend,
    });
    $trend_cv->include_adjustment('info', $avg_spot);

    return $trend_cv;
}

has more_than_short_term_cutoff => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_more_than_short_term_cutoff {
    my $self = shift;

    return ($self->bet->get_time_to_expiry->minutes >= 15) ? 1 : 0;
}

sub calculate_intraday_bounceback {
    my ($self, $t_mins, $st_or_lt) = @_;

    my $calibration_coef = $self->coefficients->{$self->bet->underlying->symbol};
    my $slope            = $self->slope;

    my $bounceback_base_intraday_trend = $self->calculate_bounceback_base($t_mins, $st_or_lt, $self->intraday_trend->amount);

    my $bounceback_base_max_trend            = $self->calculate_bounceback_base($t_mins, $st_or_lt, ($calibration_coef->{trend_max}));
    my $bounceback_base_max_trend_with_slope = $self->calculate_bounceback_base($t_mins, $st_or_lt, ($slope * $calibration_coef->{trend_max}));

    my $bounceback_base_min_trend            = $self->calculate_bounceback_base($t_mins, $st_or_lt, ($calibration_coef->{trend_min}));
    my $bounceback_base_min_trend_with_slope = $self->calculate_bounceback_base($t_mins, $st_or_lt, ($slope * $calibration_coef->{trend_min}));

    my $bounceback_safety_max = abs($bounceback_base_max_trend - $bounceback_base_max_trend_with_slope);
    my $bounceback_safety_min = abs($bounceback_base_min_trend - $bounceback_base_min_trend_with_slope);
    my $bounceback_safety     = max($bounceback_safety_min, $bounceback_safety_max);

    if ($self->bet->category->code eq 'callput' and $st_or_lt eq '_st') {
        $bounceback_base_intraday_trend = ($self->bet->code eq 'CALL') ? $bounceback_base_intraday_trend : $bounceback_base_intraday_trend * -1;
    }
    if ($self->bet->category->code eq 'callput' and $st_or_lt eq '_lt') {
        $bounceback_safety = ($self->bet->code eq 'CALL') ? $bounceback_safety : $bounceback_safety * -1;
    }

    $bounceback_base_intraday_trend += $bounceback_safety if $self->apply_bounceback_safety;

    return $bounceback_base_intraday_trend;
}

sub calculate_bounceback_base {
    my ($self, $t_mins, $st_or_lt, $trend_value) = @_;

    my @coef_name = map { $_ . $st_or_lt } qw(A B C D);
    my $calibration_coef = $self->coefficients->{$self->bet->underlying->symbol};
    my ($coef_A, $coef_B, $coef_C, $coef_D) = map { $calibration_coef->{$_} } @coef_name;
    my $coef_D_multiplier = ($st_or_lt eq '_lt') ? 1 : 1 / $coef_D;
    my $duration_in_secs = $t_mins * 60;

    return $coef_A / ($coef_D * $coef_D_multiplier) * $duration_in_secs**$coef_B * (1 / (1 + exp($coef_C * $trend_value * $coef_D)) - 0.5);
}

sub calculate_expected_spot {
    my ($self, $t) = @_;

    my $bet = $self->bet;
    my $expected_spot =
        $self->intraday_trend->peek_amount('average_spot') * $self->calculate_intraday_bounceback($t, "_lt") * sqrt($t * 60) +
        $bet->pricing_args->{spot};
    return $expected_spot;
}

sub _get_short_term_delta_correction {
    my $self = shift;

    return $self->calculate_intraday_bounceback(min($self->bet->get_time_to_expiry->minutes, 15), "_st");
}

sub _get_long_term_delta_correction {
    my $self = shift;

    my $bet           = $self->bet;
    my $args          = $bet->pricing_args;
    my $pricing_spot  = $args->{spot};
    my $duration_mins = $args->{t} * 365 * 24 * 60;
    $duration_mins = max($duration_mins, 15);
    my $duration_t = $duration_mins / (365 * 24 * 60);                    #convert back to year's fraction
    my $expected_spot = $self->calculate_expected_spot($duration_mins);

    my @barrier_args = ($bet->two_barriers) ? ($args->{barrier1}, $args->{barrier2}) : ($args->{barrier1});
    my $spot_tv =
        $self->formula->($pricing_spot, @barrier_args, $duration_t, $bet->discount_rate, $bet->mu, $self->pricing_vol, $args->{payouttime_code});
    my $spot_tv_cv = Math::Util::CalculatedValue::Validatable->new({
        name        => 'tv_priced_with_current_spot',
        description => 'bs probability priced with current spot',
        set_by      => __PACKAGE__,
        base_amount => $spot_tv,
    });
    my $expected_spot_tv =
        $self->formula->($expected_spot, @barrier_args, $duration_t, $bet->discount_rate, $bet->mu, $self->pricing_vol, $args->{payouttime_code});

    my $delta_cv = Math::Util::CalculatedValue::Validatable->new({
        name        => 'intraday_bounceback',
        description => 'Intraday bounceback based on historical data',
        set_by      => __PACKAGE__,
        base_amount => $expected_spot_tv,
    });
    $delta_cv->include_adjustment('subtract', $spot_tv_cv);

    return $delta_cv->amount;
}

sub _build_intraday_delta_correction {
    my $self = shift;

    my $delta_c;
    my @info_cv;

    if ($self->bet->get_time_to_expiry->minutes < 10) {
        $delta_c = $self->_get_short_term_delta_correction;
    } elsif ($self->bet->get_time_to_expiry->minutes > 20) {
        $delta_c = $self->_get_long_term_delta_correction;
    } else {
        my $t     = $self->bet->get_time_to_expiry->minutes;
        my $alpha = (20 - $t) / 10;
        my $beta  = ($t - 10) / 10;

        my $short_term = $self->_get_short_term_delta_correction;
        my $long_term  = $self->_get_long_term_delta_correction;

        $delta_c = ($alpha * $short_term) + ($beta * $long_term);

        push @info_cv,
            Math::Util::CalculatedValue::Validatable->new({
                name        => 'delta_correction_short_term_value',
                description => 'delta_correction_short_term_value',
                set_by      => __PACKAGE__,
                base_amount => $short_term
            });

        push @info_cv,
            Math::Util::CalculatedValue::Validatable->new({
                name        => 'delta_correction_long_term_value',
                description => 'delta_correction_long_term_value',
                set_by      => __PACKAGE__,
                base_amount => $long_term
            });
    }

    my $delta_cv = Math::Util::CalculatedValue::Validatable->new({
        name        => 'intraday_delta_correction',
        description => 'Intraday delta correction based on historical data',
        set_by      => __PACKAGE__,
        base_amount => $delta_c,
    });

    $delta_cv->include_adjustment('info', $_) for @info_cv;

    return $delta_cv;
}

=head1 intraday_vanilla_delta

The delta for a vanilla call with the same parameters as this bet.

=cut

sub _build_intraday_vanilla_delta {
    my $self = shift;

    my $bet           = $self->bet;
    my $args          = $bet->pricing_args;
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
        1  => 0.15,
        15 => 0.01,
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
    my $open_at_start = $bet->underlying->calendar->is_open_at($bet->date_start);

    if ($open_at_start and $bet->underlying->is_in_quiet_period) {
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

    $risk_markup->include_adjustment('add', $self->vol_spread_markup);

    if ($self->apply_spot_jump_markup) {
        my $spot_jump_markup = Math::Util::CalculatedValue::Validatable->new({
            name        => 'spot_jump_markup',
            description => '10% markup for spot jump',
            set_by      => __PACKAGE__,
            base_amount => 0.1,
        });
        $risk_markup->include_adjustment('add', $spot_jump_markup);
    }

    if (not $self->bet->is_atm_bet and $bet->remaining_time->minutes <= 15) {
        my $amount                         = $shortterm_risk_interpolator->linear($bet->remaining_time->minutes);
        my $shortterm_kurtosis_risk_markup = Math::Util::CalculatedValue::Validatable->new({
            name        => 'short_term_kurtosis_risk_markup',
            description => 'shortterm markup added for kurtosis risk for contract less than 15 minutes',
            set_by      => __PACKAGE__,
            base_amount => $amount,
        });
        $risk_markup->include_adjustment('add', $shortterm_kurtosis_risk_markup);
    }

    return $risk_markup;
}

has apply_spot_jump_markup => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_apply_spot_jump_markup {
    my $self = shift;
    my $hour = $self->bet->date_pricing->hour + 0;
    # we only want to charge this markup during market inefficient period 20:00 GMT to end of day
    return 0 if $hour < 20;
    # 3 is 3 times standard deviation.
    # 0.03 is the base volatility observed for one minute during inefficient period.
    my $metric_benchmark = 3 * 0.03 * sqrt(60 / (86400 * 365));
    my $jump_metric = $self->jump_metric;
    return 0 if abs($jump_metric) < $metric_benchmark;
    return 1 if ($jump_metric > 0 and $self->bet->code eq 'CALL');
    return 1 if ($jump_metric < 0 and $self->bet->code eq 'PUT');
    return 0;
}

has jump_metric => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_jump_metric {
    my $self = shift;

    my $bet = $self->bet;
    # jump metric is built on top of 2-minute lookback window.
    my @ticks = sort { $a <=> $b } map { $_->{quote} } @{
        $self->tick_source->retrieve({
                underlying   => $bet->underlying,
                interval     => Time::Duration::Concise->new(interval => '2m'),
                ending_epoch => $bet->date_pricing->epoch,
                aggregated   => 0,
            })};

    my $median = do {
        my $median_spot = $bet->pricing_args->{spot};
        if (@ticks > 1) {
            my $size  = @ticks;
            my $index = int($size / 2);
            $median_spot = ($size % 2) ? $ticks[$index] : (($ticks[$index] + $ticks[$index - 1]) / 2);
        } else {
            # if redis cache is close to empty, we want to know about it.
            warn "Failed to fetch ticks from redis cache for " . $bet->underlying->symbol;
        }
        $median_spot;
    };

    my $metric = ($median - $bet->pricing_args->{spot}) / $median;

    return $metric;
}

has [qw(intraday_vega_correction intraday_vega)] => (
    is         => 'ro',
    lazy_build => 1,
);

has [qw(_vega_formula _delta_formula)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_intraday_vega_correction {
    my $self = shift;

    my $vmr = BOM::System::Config::quants->{commission}->{intraday}->{historical_vol_meanrev};
    my $vc  = Math::Util::CalculatedValue::Validatable->new({
        name        => 'vega_correction',
        description => 'correction for uncertianty of vol',
        set_by      => 'quants.commission.intraday.historical_vol_meanrev',
        base_amount => $vmr,
    });

    $vc->include_adjustment('multiply', $self->intraday_vega);
    $vc->include_adjustment('multiply', $self->long_term_prediction);

    return $vc;
}

has [qw(economic_events_volatility_risk_markup economic_events_spot_risk_markup)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_economic_events_volatility_risk_markup {
    my $self = shift;

    my $markup_base_amount = 0;
    # since we are parsing in both vols now, we just check for difference in vol to determine if there's a markup
    if ($self->pricing_vol != $self->news_adjusted_pricing_vol) {
        my $tv_without_news = $self->base_probability->amount;
        my $tv_with_news    = $self->clone({
                pricing_vol    => $self->news_adjusted_pricing_vol,
                intraday_trend => $self->intraday_trend,
            })->base_probability->amount;
        $markup_base_amount = max(0, $tv_with_news - $tv_without_news);
    }

    my $markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'economic_events_volatility_risk_markup',
        description => 'markup to account for volatility risk of economic events',
        set_by      => __PACKAGE__,
        base_amount => $markup_base_amount,
    });

    return $markup;
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
    my $news_array        = $self->_get_economic_events($lookback, $end);

    my @combined = (0) x scalar(@time_samples);
    foreach my $news (@$news_array) {
        my $effective_news_time = _get_effective_news_time($news->{release_time}, $start->epoch, $contract_duration);
        # +1e-9 is added to prevent a division by zero error if news magnitude is 1
        my $decay_coef = -log(2 / ($news->{magnitude} + 1e-9)) / $news->{duration};
        my @triangle;
        foreach my $time (@time_samples) {
            if ($time < $effective_news_time) {
                push @triangle, 0;
            } else {
                my $chunk = $news->{bias} * exp(-$decay_coef * ($time - $effective_news_time));
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

my $news_categories = LoadFile('/home/git/regentmarkets/bom-market/config/files/economic_events_categories.yml');
sub _get_economic_events {
    my ($self, $start, $end) = @_;

    my $underlying = $self->bet->underlying;

    my $raw_events = Quant::Framework::EconomicEventCalendar->new({
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader($underlying->for_date),
        }
        )->get_latest_events_for_period({
            from => Date::Utility->new($start),
            to   => Date::Utility->new($end)});

    my $default_underlying = 'frxUSDJPY';
    my @events;
    foreach my $event (@$raw_events) {
        my $event_name = $event->{event_name};
        $event_name =~ s/\s/_/g;
        my $key = first { exists $news_categories->{$_} }
        map { (
                $_ . '_' . $event->{symbol} . '_' . $event->{impact} . '_' . $event_name,
                $_ . '_' . $event->{symbol} . '_' . $event->{impact} . '_default'
                )
        } ($underlying->symbol, $default_underlying);

        my $news_parameters = $news_categories->{$key};
        next unless $news_parameters;
        $news_parameters->{release_time} = $event->{release_date};
        push @events, $news_parameters;
    }

    return \@events;
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

has volatility_scaling_factor => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_volatility_scaling_factor',
);

sub _build_volatility_scaling_factor {
    return shift->bet->pricing_args->{volatility_scaling_factor};
}

has vol_spread_markup => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_vol_spread_markup',
);

sub _build_vol_spread_markup {
    my $self = shift;

    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'vol_spread_markup',
        set_by      => __PACKAGE__,
        description => 'markup added to account for variable ticks interval for volatility calculation.',
        base_amount => 0.1 * (1 - ($self->volatility_scaling_factor)**2),
    });
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
