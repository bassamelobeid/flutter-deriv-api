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
use BOM::Platform::QuantsConfig;
use BOM::Platform::Chronicle;

use Pricing::Engine::Intraday::Forex::Base;
use Pricing::Engine::Markup::EconomicEventsSpotRisk;

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

has base_engine => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_base_engine {
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

    return Pricing::Engine::Intraday::Forex::Base->new(%args,);
}

sub _build_base_probability {
    my $self = shift;

    return $self->base_engine->base_probability;
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
        minimum     => 0,                                                          # no discounting
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

    if (    $bet->trading_calendar->is_open_at($bet->underlying->exchange, $bet->date_start)
        and $self->is_in_quiet_period($bet->date_pricing))
    {
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

    if ($bet->is_atm_bet) {
        $risk_markup->include_adjustment(
            'add',
            Math::Util::CalculatedValue::Validatable->new({
                    name        => 'intraday_eod_markup',
                    description => '5% markup for inefficient period',
                    set_by      => __PACKAGE__,
                    base_amount => 0.05,
                })) if $self->inefficient_period;
    } else {
        $risk_markup->include_adjustment('add', $self->vol_spread_markup);
        $risk_markup->include_adjustment(
            'add',
            Math::Util::CalculatedValue::Validatable->new({
                    name        => 'intraday_eod_markup',
                    description => '10% markup for inefficient period',
                    set_by      => __PACKAGE__,
                    base_amount => 0.1,
                })) if $self->inefficient_period;
        $risk_markup->include_adjustment(
            'add',
            Math::Util::CalculatedValue::Validatable->new({
                    name        => 'short_term_kurtosis_risk_markup',
                    description => 'shortterm markup added for kurtosis risk for contract less than 15 minutes',
                    set_by      => __PACKAGE__,
                    base_amount => $shortterm_risk_interpolator->linear($bet->remaining_time->minutes),
                })) if $bet->remaining_time->minutes <= 15;
    }

    return $risk_markup;
}

sub event_markup {
    my $self = shift;

    my @markups = (0);
    if ($self->bet->category_code eq 'callput' && !$self->bet->is_atm_bet) {
        my $for_date = $self->bet->underlying->for_date;
        my $qc       = BOM::Platform::QuantsConfig->new(
            chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader($for_date),
            for_date         => $for_date
        );
        my $event_markup = $qc->get_config(
            'commission',
            +{
                contract_type     => $self->bet->code,
                underlying_symbol => $self->bet->underlying->symbol
            });
        my $delta = $self->intraday_vanilla_delta->amount;
        $delta = 1 - $delta if $self->bet->pricing_code =~ /PUT/;
        my $c_start = $self->bet->effective_start->epoch;
        my $c_end   = $self->bet->date_expiry->epoch;

        foreach my $c (@$event_markup) {
            my $start_epoch     = Date::Utility->new($c->{start_time})->epoch;
            my $end_epoch       = Date::Utility->new($c->{end_time})->epoch;
            my $valid_timeframe = ($c_start >= $start_epoch && $c_start <= $end_epoch)
                || ($c_end >= $start_epoch && $c_end <= $end_epoch || ($c_start < $start_epoch && $c_end > $end_epoch));
            foreach my $partition (@{$c->{partitions}}) {
                my @delta_range = split '-', $partition->{partition_range};
                my $valid_delta = ($delta >= $delta_range[0] && $delta <= $delta_range[1]);
                if ($valid_timeframe && $valid_delta) {
                    push @markups, calculate_event_adjustment($delta, $partition);
                }
            }
        }
    }

    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'event_markup',
        description => 'markup to account for volatility risk of economic events',
        set_by      => __PACKAGE__,
        base_amount => max(@markups),
    });
}

sub calculate_event_adjustment {
    my ($delta, $c) = @_;

    my $cap = $c->{cap_rate};

    die 'max adjustment is not defined' unless defined $cap;
    return $cap if $c->{flat};

    if (my @missing = grep { not defined $c->{$_} or $c->{$_} eq '' } qw(width floor_rate centre_offset)) {
        die 'missing required parameters[' . (join ',', @missing) . '] to calculate commission';
    }

    my $width         = max(0.01, $c->{width});
    my $floor         = $c->{floor_rate};
    my $centre_offset = $c->{centre_offset};

    return min($cap, $cap - ($cap - $floor) * (1 - (2 / $width * abs($delta - 0.5 - $centre_offset))**3)**3);
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

sub vol_spread_markup {
    my $self = shift;

    my $bet = $self->bet;

    my $long_term_average_vol = 0.07;
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

=head2 is_in_quiet_period

Are we currently in a quiet traidng period for this underlying?
Keeping this as a method will allow us to have long-lived objects

=cut

sub is_in_quiet_period {
    my ($self, $date) = @_;

    my $underlying = $self->bet->underlying;
    die 'date must be specified when requesting for quiet period' unless $date;

    my $quiet = 0;

    if ($underlying->market->name eq 'forex') {
        # Pretty much everything trades in these big centers of activity
        my @check_if_open = ('LSE', 'FSE', 'NYSE');

        my @currencies = ($underlying->asset_symbol, $underlying->quoted_currency_symbol);

        if (grep { $_ eq 'JPY' } @currencies) {

            # The yen is also heavily traded in
            # Australia, Singapore and Tokyo
            push @check_if_open, ('ASX', 'SES', 'TSE');
        } elsif (
            grep {
                $_ eq 'AUD'
            } @currencies
            )
        {

            # The Aussie dollar is also heavily traded in
            # Australia and Singapore
            push @check_if_open, ('ASX', 'SES');
        }
        # If any of the places we've listed have an exchange open, we are not in a quiet period.
        $quiet = (any { $self->bet->trading_calendar->is_open_at(Finance::Exchange->create_exchange($_), $date) } @check_if_open) ? 0 : 1;
    }

    return $quiet;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
