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
use BOM::Config::QuantsConfig;
use BOM::Config::Chronicle;
use Pricing::Engine::Intraday::Forex::Base;
use Pricing::Engine::Markup::EconomicEventsSpotRisk;
use Pricing::Engine::Markup::EqualTie;
use Pricing::Engine::Markup::CustomCommission;
use Pricing::Engine::Markup::HourEndMarkup;
use Pricing::Engine::Markup::HourEndDiscount;
use Pricing::Engine::Markup::IntradayMeanReversionMarkup;
use Pricing::Engine::Markup::RollOverMarkup;
use Math::Util::CalculatedValue::Validatable;

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

has base_engine => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_base_engine {
    my $self = shift;

    my $bet          = $self->bet;
    my $pricing_args = $bet->_pricing_args;
    my %args         = (
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

has apply_rollover_markup => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_apply_rollover_markup {
    my $self = shift;

    my $bet = $self->bet;

    return 0 if $bet->underlying->market->name ne 'forex';

    return 0 if $bet->date_expiry->hour < 20;
    my $rollover_date = $bet->volsurface->rollover_date($bet->date_pricing);

    return 1
        if ((
               ($bet->date_start->hour >= ($rollover_date->hour - 1))
            or ($bet->date_expiry->hour >= $rollover_date->hour))
        and ($bet->date_start->hour < ($rollover_date->hour + 2)));

    return 0;
}
has mean_reversion_markup => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_mean_reversion_markup {
    my $self = shift;

    my $markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'mean_reversion_markup',
        description => 'Intraday mean reversion markup.',
        set_by      => __PACKAGE__,
        base_amount => 0,
    });

    my $bet = $self->bet;

    return $markup unless ($bet->market->name eq 'forex' or $bet->market->name eq 'commodities');

    return $markup if $bet->is_forward_starting;

    my $bet_duration = $bet->timeindays->amount * 24 * 60;
    # Maximum lookback period is 30 minutes
    my $lookback_duration = min(30, $bet_duration);
    #  We did not do any ajdusment if there is nothing to lookback ie either monday morning or the next day after early close
    return $markup
        unless $bet->trading_calendar->is_open_at($bet->underlying->exchange, $bet->date_start->minus_time_interval($lookback_duration . 'm'));
    my $bs_probability = $self->base_probability->base_amount;
    my $min_max        = $bet->spot_min_max($bet->date_start->minus_time_interval($lookback_duration . 'm'));

    my %params = (
        min_max        => $min_max,
        bs_probability => $bs_probability,
        spot           => $bet->pricing_spot,
        pricing_code   => $bet->pricing_code
    );

    $markup->include_adjustment('add', Pricing::Engine::Markup::IntradayMeanReversionMarkup->new(%params)->markup);

    return $markup;
}
has hour_end_markup => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_hour_end_markup {
    my $self = shift;

    my $markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'hour_end_markup',
        description => 'Intraday hour end markup.',
        set_by      => __PACKAGE__,
        base_amount => 0,
    });
    my $bet = $self->bet;
    my %params = (hour_end_markup_parameters => $bet->hour_end_markup_parameters);
    $markup->include_adjustment('add', Pricing::Engine::Markup::HourEndMarkup->new(%params)->markup);
    # we do not apply discount for forward starting contracts.
    $markup->include_adjustment('add', Pricing::Engine::Markup::HourEndDiscount->new(%params)->markup)
        if not $bet->is_forward_starting and BOM::Config::Runtime->instance->app_config->quants->enable_hour_end_discount;

    return $markup;
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

    my $bet = $self->bet;
    # minimum of 0 is removed for end of hour discount
    my $risk_markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'risk_markup',
        description => 'A set of markups added to accommodate for pricing risk',
        set_by      => __PACKAGE__,
        base_amount => 0,
    });

    $risk_markup->include_adjustment('add', $self->economic_events_markup);

    if (%{$self->bet->hour_end_markup_parameters} and $self->hour_end_markup->amount > $self->mean_reversion_markup->amount) {

        $risk_markup->include_adjustment('add', $self->hour_end_markup);

    } else {

        $risk_markup->include_adjustment('add', $self->mean_reversion_markup);

    }

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
    $risk_markup->include_adjustment(
        'add',
        Pricing::Engine::Markup::EqualTie->new(
            underlying_symbol => $bet->underlying->symbol,
            timeinyears       => $bet->timeinyears->amount
        )->markup
    ) if $self->apply_equal_tie_markup;
    # Rollover markup should only app]y for contract that start after 1 hour before rollover time (ie 16NYT) or contract end after rollover time (ie 17NYT)
    $risk_markup->include_adjustment(
        'add',
        Pricing::Engine::Markup::RollOverMarkup->new(
            interest_rate_difference => $bet->q_rate - $bet->r_rate,
            rollover_hour            => $bet->volsurface->rollover_date($bet->date_pricing),
            date_start               => $bet->date_start,
            date_expiry              => $bet->date_expiry,
            pricing_code             => $bet->pricing_code
        )->markup
    ) if $self->apply_rollover_markup;

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

    return ($self->is_in_quiet_period($self->bet->date_pricing)) ? 0.035 : 0.07;
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

sub get_compatible {
    my ($class, $to_load, $metadata) = @_;

    return BOM::Product::Pricing::Engine->is_compatible($to_load, $metadata) ? $class : undef;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
