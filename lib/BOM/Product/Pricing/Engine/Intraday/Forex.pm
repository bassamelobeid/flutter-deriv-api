package BOM::Product::Pricing::Engine::Intraday::Forex;

use Moose;
extends 'BOM::Product::Pricing::Engine::Intraday';

use JSON qw(from_json);
use List::Util qw(max min sum);
use Sereal qw(decode_sereal);
use YAML::XS qw(LoadFile);

use BOM::Platform::Context qw(request localize);
use BOM::Platform::Runtime;
use BOM::Utility::ErrorStrings qw( format_error_string );
use Math::Business::BlackScholes::Binaries::Greeks::Delta;
use Math::Business::BlackScholes::Binaries::Greeks::Vega;
use VolSurface::Utils qw( get_delta_for_strike );
use BOM::Platform::Static::Config;

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

has [qw(average_tick_count long_term_prediction)] => (
    is         => 'ro',
    lazy_build => 1,
);

has [qw(pricing_vol news_adjusted_pricing_vol)] => (
    is         => 'rw',
    lazy_build => 1,
);

sub _build_news_adjusted_pricing_vol {
    return shift->bet->pricing_args->{iv_with_news};
}

sub _build_average_tick_count {
    return shift->bet->pricing_args->{average_tick_count};
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
    qw(probability intraday_delta_correction short_term_prediction long_term_prediction economic_events_markup intraday_trend intraday_vanilla_delta commission_markup risk_markup)
    ] => (
    is         => 'ro',
    lazy_build => 1,
    );

## PRIVATE ##
has [qw(_delta_formula _vega_formula)] => (
    is         => 'ro',
    lazy_build => 1,
);

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
        base_amount => $self->formula->($self->_formula_args),
    });

    $ifx_prob->include_adjustment('add',  $self->intraday_delta_correction);
    $ifx_prob->include_adjustment('add',  $self->intraday_vega_correction);
    $ifx_prob->include_adjustment('info', $self->intraday_vanilla_delta);

    my $min_prob = 0.1;
    if ($ifx_prob->amount < $min_prob) {
        $ifx_prob->add_errors({
                message => format_error_string(
                    'Theo probability below the minimum acceptable',
                    probability => $ifx_prob->amount,
                    min         => $min_prob
                ),
                ,
                message_to_client => localize('Barrier outside acceptable range.'),
            });
    }

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

=head1 intraday_trend

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
    if (!@ticks) {
        $avg_spot->add_errors({
            message           => 'No ticks retrieved to determine trend.',
            message_to_client => localize('Missing market data.'),
        });
    }

    my $trend            = (($bet->pricing_args->{spot} - $avg_spot->amount) / $avg_spot->amount) / sqrt($duration_in_secs);
    my $calibration_coef = $self->coefficients->{$bet->underlying->symbol};
    my $trend_cv         = Math::Util::CalculatedValue::Validatable->new({
        name        => 'intraday_trend',
        description => 'Intraday trend based on historical data',
        minimum     => $calibration_coef->{trend_min},
        maximum     => $calibration_coef->{trend_max},
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

    my @coef_name = map { $_ . $st_or_lt } qw(A B C D);
    my $calibration_coef = $self->coefficients->{$self->bet->underlying->symbol};
    my ($coef_A, $coef_B, $coef_C, $coef_D) = map { $calibration_coef->{$_} } @coef_name;
    my $coef_D_multiplier = ($st_or_lt eq '_lt') ? 1 : 1 / $coef_D;

    my $duration_in_secs = $t_mins * 60;
    my $bounceback_base =
        $coef_A /
        ($coef_D * $coef_D_multiplier) *
        $duration_in_secs**$coef_B *
        (1 / (1 + exp($coef_C * $self->intraday_trend->amount * $coef_D)) - 0.5);

    if ($self->bet->category->code eq 'callput' and $st_or_lt eq '_st') {
        $bounceback_base = ($self->bet->code eq 'CALL') ? $bounceback_base : $bounceback_base * -1;
    }

    return $bounceback_base;
}

sub calculate_expected_spot {
    my ($self, $t) = @_;

    my $bet = $self->bet;
    my $expected_spot =
        $self->calculate_intraday_bounceback($t, "_lt") * $self->intraday_trend->peek_amount('average_spot') * sqrt($t * 60) +
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
        language    => request()->language,
        name        => 'intraday_vanilla_delta',
        description => 'The delta of a vanilla call with the same parameters as this bet',
        set_by      => __PACKAGE__,
        base_amount => $barrier_delta,
    });
}

=head1 commission_markup

Fixed commission for the bet

=cut

sub _build_commission_markup {
    my $self = shift;

    my $bet = $self->bet;
    my $comm_base_amount =
        ($self->bet->built_with_bom_parameters)
        ? BOM::Platform::Static::Config::quants->{commission}->{resell_discount_factor}
        : 1;

    my $comm_scale = Math::Util::CalculatedValue::Validatable->new({
        name        => 'commission_scaling_factor',
        description => 'A scaling factor to control commission',
        set_by      => __PACKAGE__,
        base_amount => $comm_base_amount,
    });

    my $comm_markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'commission_markup',
        description => 'fixed commission markup',
        set_by      => __PACKAGE__,
    });

    my $fixed_comm = Math::Util::CalculatedValue::Validatable->new({
        name        => 'intraday_historical_fixed',
        description => 'fixed commission markup for Intraday::Forex pricer',
        set_by      => __PACKAGE__,
        base_amount => BOM::Platform::Static::Config::quants->{commission}->{intraday}->{historical_fixed},
    });

    $comm_markup->include_adjustment('info',  $comm_scale);
    $comm_markup->include_adjustment('reset', $fixed_comm);

    my $stitch = Math::Util::CalculatedValue::Validatable->new({
        name        => 'stitching_adjustment',
        description => 'to smooth transitions when we change engines',
        set_by      => __PACKAGE__,
        minimum     => 0,
        base_amount => 0,
    });
    my $standard         = $self->digital_spread_markup;
    my $spread_to_markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'spread_to_markup',
        description => 'Apply half of spread to each side',
        set_by      => __PACKAGE__,
        base_amount => 2,
    });

    $stitch->include_adjustment('reset',    $standard);
    $stitch->include_adjustment('divide',   $spread_to_markup);
    $stitch->include_adjustment('subtract', $fixed_comm);
    my $duration_factor = Math::Util::CalculatedValue::Validatable->new({
        name        => 'Factor to adjust for bet duration',
        description => 'to smooth transition',
        set_by      => __PACKAGE__,
        base_amount => $bet->remaining_time->minutes / 400,
    });

    $stitch->include_adjustment('multiply', $duration_factor);

    $comm_markup->include_adjustment('add', $stitch);

    my $open_at_start = $bet->underlying->exchange->is_open_at($bet->date_start);

    if (    $open_at_start
        and defined $self->average_tick_count
        and $self->average_tick_count < 4)
    {
        my $extra_uncertainty = Math::Util::CalculatedValue::Validatable->new({
            name        => 'model_uncertainty_markup',
            description => 'Factor to apply when backtesting was uncertain',
            set_by      => __PACKAGE__,
            base_amount => 2,
        });
        $extra_uncertainty->include_adjustment('info', $self->long_term_vol);

        $comm_markup->include_adjustment('multiply', $extra_uncertainty);
    }
    if ($open_at_start and $bet->underlying->is_in_quiet_period) {
        my $quiet_period_markup = Math::Util::CalculatedValue::Validatable->new({
            name        => 'quiet_period_markup',
            description => 'Intraday::Forex markup factor for underlyings in the quiet period',
            set_by      => __PACKAGE__,
            base_amount => 0.01,
        });
        $comm_markup->include_adjustment('add', $quiet_period_markup);
    }
    if ($bet->is_path_dependent) {
        my $path_dependent_markup_factor = Math::Util::CalculatedValue::Validatable->new({
            name        => 'path_dependent_markup',
            description => 'Intraday::Forex markup factor for path dependent contracts',
            set_by      => __PACKAGE__,
            base_amount => 2,
        });
        $comm_markup->include_adjustment('multiply', $path_dependent_markup_factor);
    }

    $comm_markup->include_adjustment('multiply', $comm_scale);

    return $comm_markup;
}

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
        base_amount => 0,
    });

    $risk_markup->include_adjustment('add', $self->economic_events_markup);
    $risk_markup->include_adjustment('add', $self->eod_market_risk_markup);

    if (not $bet->is_atm_bet) {
        my $iv_risk = Math::Util::CalculatedValue::Validatable->new({
            name        => 'intraday_historical_iv_risk',
            description => 'Intraday::Forex markup for IV contracts only.',
            set_by      => 'quants.commission.intraday.historical_iv_risk',
            base_amount => BOM::Platform::Static::Config::quants->{commission}->{intraday}->{historical_iv_risk} / 100,
        });
        $risk_markup->include_adjustment('add', $iv_risk);
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
    if ($bet->underlying->submarket->name eq 'minor_pairs') {
        my $minor_fx_market_markup = Math::Util::CalculatedValue::Validatable->new({
            name        => 'minor_fx_market_markup',
            description => 'Intraday::Forex markup factor for minor fx pairs',
            set_by      => __PACKAGE__,
            base_amount => 0.02,
        });
        $risk_markup->include_adjustment('add', $minor_fx_market_markup);
    }

    return $risk_markup;
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

    my $vmr = BOM::Platform::Static::Config::quants->{commission}->{intraday}->{historical_vol_meanrev};
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

has economic_events_volatility_risk_markup => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_economic_events_volatility_risk_markup {
    my $self = shift;

    my $markup_base_amount = 0;
    # since we are parsing in both vols now, we just check for difference in vol to determine if there's a markup
    if ($self->pricing_vol != $self->news_adjusted_pricing_vol) {
        my $tv_without_news = $self->probability->amount;
        my $tv_with_news    = $self->clone({
                pricing_vol    => $self->news_adjusted_pricing_vol,
                intraday_trend => $self->intraday_trend,
            })->probability->amount;
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

no Moose;
__PACKAGE__->meta->make_immutable;
1;
