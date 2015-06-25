package BOM::Product::Pricing::Engine::Intraday::Forex;

use Moose;
extends 'BOM::Product::Pricing::Engine::Intraday';
with 'BOM::Product::Pricing::Engine::Role::EuroTwoBarrier';

use JSON qw(from_json);
use List::Util qw(max min sum);
use YAML::CacheLoader;

use BOM::Platform::Context qw(request localize);
use BOM::Platform::Runtime;
use Math::Business::BlackScholes::Binaries::Greeks::Delta;
use Math::Business::BlackScholes::Binaries::Greeks::Vega;
use VolSurface::Utils qw( get_delta_for_strike );

sub BUILD {
    my $self = shift;

    is_compatible($self->bet);

    return;
}

sub clone {
    my ($self, $changes) = @_;
    return $self->new({
        bet => $self->bet,
        %$changes
    });
}

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
            CALL        => 1,
            PUT         => 1,
            EXPIRYMISS  => 1,
            EXPIRYRANGE => 1,
            ONETOUCH    => 1,
            NOTOUCH     => 1,
        };
    },
);

has [
    qw(probability intraday_bounceback intraday_delta intraday_vega delta_correction vega_correction short_term_prediction  economic_events_markup intraday_trend intraday_mu intraday_vanilla_delta commission_markup risk_markup)
    ] => (
    is         => 'ro',
    lazy_build => 1,
    );

## PRIVATE ##
has [qw(_delta_formula _vega_formula)] => (
    is         => 'ro',
    lazy_build => 1,
);

has _cached_economic_events_info => (
    is      => 'ro',
    isa     => 'ArrayRef',
    default => sub { [] },
);

sub is_compatible {
    my $bet = shift;

    my %ref = map { $_ => 1 } BOM::Market::UnderlyingDB->instance->symbols_for_intraday_fx;

    return (defined $ref{$bet->underlying->symbol} and BOM::Product::Pricing::Engine::Intraday::is_compatible($bet));
}

=head1 probability

The final theoretical probability after corrections.  Math::Util::CalculatedValue::Validatable

=cut

sub _build_probability {
    my ($self) = @_;

    my $bet         = $self->bet;
    my $bet_minutes = $bet->calendar_minutes->amount;
    my $args        = $bet->pricing_args;

    my $ifx_prob;
    if ($bet->two_barriers and not $bet->is_path_dependent) {
        $ifx_prob = $self->euro_two_barrier_probability;

        my @ordered_from_atm =
            sort { abs(0.5 - $b) <=> abs(0.5 - $a) }
            map  { $_->peek_amount('intraday_vanilla_delta') }
            map  { $ifx_prob->peek($_ . '_theoretical_probability') } qw(call put);

        my $dbe_delta = Math::Util::CalculatedValue::Validatable->new({
            language    => request()->language,
            name        => 'intraday_vanilla_delta',
            description => 'A replaced value for the two barrier bet, representing the furthest from ATM for the two barriers',
            set_by      => __PACKAGE__,
            base_amount => $ordered_from_atm[0],
        });
        $ifx_prob->replace_adjustment($dbe_delta);
    } else {
        $ifx_prob = Math::Util::CalculatedValue::Validatable->new({
            name        => lc($bet->code) . '_theoretical_probability',
            description => 'BS pricing based on realized vols',
            set_by      => __PACKAGE__,
            minimum     => 0,
            maximum     => 1,
            base_amount => $self->formula->($self->_formula_args),
        });

        $ifx_prob->include_adjustment('add', $self->delta_correction);
        if ($bet->is_path_dependent) {
            $ifx_prob->include_adjustment('add', $self->vega_correction);
        } else {
            $ifx_prob->include_adjustment('subtract', $self->vega_correction);
        }

        $ifx_prob->include_adjustment('info', $self->intraday_vanilla_delta);
        $ifx_prob->include_adjustment('info', $self->intraday_mu);
    }

    if ($ifx_prob->amount < 0.1) {
        $ifx_prob->add_errors({
            message           => 'Theo probability [' . $ifx_prob->amount . '] is below the minimum acceptable range [0.1]',
            message_to_client => localize('Barrier outside acceptable range.'),
        });
    }

    return $ifx_prob;
}

=head1 intraday_bounceback

The 'expected' bounceback for mean-reversion in spot.  We use
different values for customers and BOM to keep our risk in check.

Math::Util::CalculatedValue::Validatable

=cut

sub _build_intraday_bounceback {
    my $self = shift;

    my $bet      = $self->bet;
    my $how_long = $bet->calendar_minutes->amount;

# The bounceback value is based on emprical studies which suggest a bounce back over the duration
# Zeroes out in very short-term (under 15 minutes) and very long-term (over 10 hours)
# It is currently impossible to buildthis engine outside of these ranges, but the condition remains for posterity
    my $sides = from_json(BOM::Platform::Runtime->instance->app_config->quants->commission->intraday->historical_bounceback);
    my $bb    = {};
    my $type  = ($bet->is_path_dependent) ? 'path' : 'euro';
    foreach my $which (keys %{$sides}) {
        $bb->{$which} = Math::Util::CalculatedValue::Validatable->new({
            name => join('_', ('bounceback', $which, $type)),
            description => 'expect mean reversion over the next ' . $how_long . ' minutes',
            set_by      => 'quants.commission.intraday.historical_bounceback',
            base_amount => $sides->{$which}->{$type} * min(0.5 * $how_long, ((600 - $how_long) / 600)),
        });
    }

    return $bb;
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

=head1 delta_correction

The correction for uncertainty of spot, formed from the intraday_delta, intraday_trend and intraday_bounceback.

Math::Util::CalculatedValue::Validatable

=cut

sub _build_delta_correction {
    my $self = shift;
    my $bet  = $self->bet;
    # This is for preventing FLASHU/FLASHD delta correction in World Indices to go lower than 2%.
    # Since these contracts are similar to coin toss any price far away from 50% on the lower side can have potential for expolit.
    # We will revisit the delta correction again to remove this flooring
    my @min =
          ($self->bet->underlying->submarket->name eq 'smart_fx')
        ? (minimum => -0.02)
        : ();

    my $dc = Math::Util::CalculatedValue::Validatable->new({
        name        => 'delta_correction',
        description => 'correction for uncertianty of spot',
        set_by      => __PACKAGE__,
        base_amount => -1,
        @min,
    });

    $dc->include_adjustment('multiply', $self->intraday_delta);
    $dc->include_adjustment('multiply', $self->intraday_trend);
    my $which_bounce = ($dc->amount < 0) ? 'client' : 'BOM';
    $dc->include_adjustment('multiply', $self->intraday_bounceback->{$which_bounce . '_favor'});
    return $dc;
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

=head1 vega_correction

The correction to apply to the theorteical price for uncertaity of vol.  Based on
long_term_vol and intraday_vega.

Math::Util::CalculatedValue::Validatable

=cut

sub _build_vega_correction {
    my $self = shift;

    my $vmr = BOM::Platform::Runtime->instance->app_config->quants->commission->intraday->historical_vol_meanrev;
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

    foreach my $event (@{$self->_cached_economic_events_info}) {
        my $info = Math::Util::CalculatedValue::Validatable->new({
            name        => $event->event_name . ' for ' . $event->symbol . ' at ' . $event->release_date->datetime,
            description => 'economic events affecting this bet',
            set_by      => __PACKAGE__,
            base_amount => $event->impact,
        });
        $markup->include_adjustment('info', $info);
    }

    return $markup;
}

=head1 intraday_trend

The current observed trend in the market movements.  Math::Util::CalculatedValue::Validatable

=cut

sub _build_intraday_trend {
    my $self = shift;

    my $ticks_period = $self->_trend_interval;

    my $trend = Math::Util::CalculatedValue::Validatable->new({
        name        => 'intraday_trend',
        description => 'trend over the last ' . $ticks_period->as_string,
        set_by      => __PACKAGE__,
        base_amount => 0,
    });

    $trend->include_adjustment('reset',    $self->period_closing_value);
    $trend->include_adjustment('subtract', $self->period_opening_value);

    return $trend;
}

=head1 intraday_mu

The drift to use in pricing.  Math::Util::CalculatedValue::Validatable

Presently always set to 0, but included for completeness.

=cut

sub _build_intraday_mu {
    my $self = shift;

    my $bet = $self->bet;
    my $mu  = Math::Util::CalculatedValue::Validatable->new({
        name        => 'intraday_mu',
        description => 'Intraday drift from historical data.',
        set_by      => __PACKAGE__,
        base_amount => 0,
    });

    return $mu;
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
        ? BOM::Platform::Runtime->instance->app_config->quants->commission->resell_discount_factor
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
        base_amount => BOM::Platform::Runtime->instance->app_config->quants->commission->intraday->historical_fixed,
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
        base_amount => $bet->calendar_minutes->amount / 400,
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
            base_amount => BOM::Platform::Runtime->instance->app_config->quants->commission->intraday->historical_iv_risk / 100,
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

sub _build__attrs_safe_for_eq_ticks_reuse {

# This is not a comprehensive list of safe attributes, but includes the ones which
# are slow enough to make use want to reuse them
    return [qw(ticks_for_trend pricing_vol news_adjusted_pricing_vol)];
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
        my $tv_with_news = $self->clone({pricing_vol => $self->news_adjusted_pricing_vol})->probability->amount;
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
