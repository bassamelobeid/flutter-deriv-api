package BOM::Product::Pricing::Engine::Role::StandardMarkup;

=head1 NAME

BOM::Product::Pricing::Engine::Role::StandardMarkup

=head1 DESCRIPTION

A Moose role which provides a standard markup for exotic options.

=cut

use 5.010;
use Moose::Role;
requires 'bet';

use List::Util qw(max min sum first);
use List::MoreUtils qw(uniq);
use POSIX qw(ceil);
use YAML::CacheLoader;
use Math::Function::Interpolator;

use BOM::Platform::Context qw(request localize);
use BOM::Product::Pricing::Greeks::BlackScholes;
use BOM::MarketData::VolSurface::Utils;
use BOM::MarketData::Fetcher::EconomicEvent;

=head1 ATTRIBUTES

=cut

has [
    qw(model_markup smile_uncertainty_markup butterfly_markup vol_spread_markup spot_spread_markup risk_markup commission_markup digital_spread_markup forward_starting_markup economic_events_markup eod_market_risk_markup economic_events_spot_risk_markup)
    ] => (
    is         => 'ro',
    isa        => 'Math::Util::CalculatedValue::Validatable',
    lazy_build => 1,
    );

has [qw( commission_level commission_market commission_bet_type uses_dst_shifted_seasonality)] => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

has _volatility_seasonality_step_size => (
    is      => 'ro',
    isa     => 'Num',
    default => 100,
);

=head2 model_markup

This sub builds up the bid ask spread. This section will eventually be used to build BOM spreads and then we will be adding an extra commission on top of it.

=cut

sub _build_model_markup {
    my $self = shift;

    my $model_markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'model_markup',
        description => 'Standard markup',
        set_by      => __PACKAGE__,
    });

    $model_markup->include_adjustment('reset', $self->commission_markup);
    $model_markup->include_adjustment('add',   $self->risk_markup);

    return $model_markup;
}

sub _build_eod_market_risk_markup {
    my $self = shift;

    my $bet      = $self->bet;
    my $eod_base = 0;

    my $ny_1700 = BOM::MarketData::VolSurface::Utils->new->NY1700_rollover_date_on($bet->date_start);
    my $ny_1600 = $ny_1700->minus_time_interval('1h');

    if (
        first { $bet->market->name eq $_ } (qw(forex commodities))
            and $bet->timeindays->amount <= 3
        and (
            $ny_1600->is_before($bet->date_start)
            or (    $bet->is_intraday
                and $ny_1600->is_before($bet->date_expiry))))
    {
        $eod_base = 0.05;
    }
    my $eod_market_risk_markup = Math::Util::CalculatedValue::Validatable->new({
        language    => request()->language,
        name        => 'eod_market_risk_markup',
        description => 'Markup factor for EOD market uncertainty',
        set_by      => __PACKAGE__,
        base_amount => $eod_base,
    });

    # Only allow sale with this commission in the ATM case.
    if ($eod_base and not $bet->is_atm_bet) {
        my $message =
            ($bet->built_with_bom_parameters)
            ? localize('Resale of this contract is not offered.')
            : localize('The contract is not available after [_1] GMT.', $ny_1600->time_hhmm);
        $eod_market_risk_markup->add_errors({
            message           => 'Underlying buying suspended between NY1600 and GMT0000',
            message_to_client => $message . ' ',
            info_link         => request()->url_for('/resources/asset_index'),
            info_text         => localize('View Asset Index'),
        });
    }

    return $eod_market_risk_markup;
}

sub _build_vol_spread_markup {
    my $self = shift;

    my $comm = Math::Util::CalculatedValue::Validatable->new({
        name        => 'vol_spread_markup',
        description => 'vol spread adjustment',
        set_by      => __PACKAGE__,
        base_amount => 0,
        minimum     => 0,
        maximum     => 0.7,
    });
    my $bet = $self->bet;
    my $spread_type;

    if ($bet->is_atm_bet) {

        $spread_type = 'atm';
    } else {
        $spread_type = 'max';
    }

    my $vol_spread = Math::Util::CalculatedValue::Validatable->new({
            name        => 'vol_spread',
            description => 'The vol spread for this time',
            set_by      => 'BOM::MarketData::VolSurface',
            base_amount => $bet->volsurface->get_spread({
                    sought_point => $spread_type,
                    day          => $bet->timeindays->amount
                }
            ),
        });

    my $vega = Math::Util::CalculatedValue::Validatable->new({
        name        => 'bet_vega',
        description => 'The vega of the priced option',
        set_by      => 'BOM::Product::Pricing::Engine::Role::MarketPricedPortfolios',
        base_amount => abs($bet->vega),
    });

    $comm->include_adjustment('reset',    $vol_spread);
    $comm->include_adjustment('multiply', $vega);

    return $comm;
}

sub _build_butterfly_markup {
    my $self = shift;

    # Increase spreads if the butterfly is greater than 1%
    my $butterfly_cutoff          = 0.01;
    my $butterfly_cutoff_breached = 0;

    my $comm = Math::Util::CalculatedValue::Validatable->new({
        name        => 'butterfly_markup',
        description => 'high butterfly adjustment',
        set_by      => 'Role::StandardMarkup',
        base_amount => 0,
        minimum     => 0,
        maximum     => 0.1,
    });

    my $bet     = $self->bet;
    my $surface = $bet->volsurface;

    if (
            $bet->market->markups->apply_butterfly_markup
        and $bet->timeindays->amount == $surface->_ON_day                  # only apply butterfly markup to overnight contracts
        and $surface->original_term_for_smile->[0] == $surface->_ON_day    # does the surface have an ON tenor?
        and $surface->get_market_rr_bf($surface->original_term_for_smile->[0])->{BF_25} > $butterfly_cutoff
        )
    {
        $butterfly_cutoff_breached = 1;
    }

    # Boolean indicator of butterfly greater than cutoff condition
    my $butterfly_greater_than_cutoff = Math::Util::CalculatedValue::Validatable->new({
        name        => 'butterfly_greater_than_cutoff',
        description => 'Boolean indicator of a butterfly greater than the cutoff',
        set_by      => 'Role::StandardMarkup',
        base_amount => $butterfly_cutoff_breached,
    });
    $comm->include_adjustment('reset', $butterfly_greater_than_cutoff);

    if ($butterfly_cutoff_breached == 1) {

        # theo probability, priced at the current value
        my $actual_theoretical_value_amount = $bet->theo_probability->amount;
        my $actual_theoretical_value        = Math::Util::CalculatedValue::Validatable->new({
            name        => 'actual_theoretical_value',
            description => 'The theoretical value with the actual butterfly',
            set_by      => 'BOM::Product::Contract',
            base_amount => $actual_theoretical_value_amount,
        });

        # theo probability, priced at the butterfly_cutoff
        my $butterfly_cutoff_theoretical_value_amount = $self->butterfly_cutoff_theoretical_value_amount($butterfly_cutoff);
        my $butterfly_cutoff_theoretical_value        = Math::Util::CalculatedValue::Validatable->new({
            name        => 'butterfly_cutoff_theoretical_value',
            description => 'The theoretical value at the butterfly_cutoff',
            set_by      => 'BOM::Product::Contract',
            base_amount => $butterfly_cutoff_theoretical_value_amount,
        });

        # difference between the two theo probabilities
        my $difference_of_theoretical_values = Math::Util::CalculatedValue::Validatable->new({
            name        => 'difference_of_theoretical_values',
            description => 'The difference of theoretical values',
            set_by      => 'Role::StandardMarkup',
        });

        $difference_of_theoretical_values->include_adjustment('reset',    $actual_theoretical_value);
        $difference_of_theoretical_values->include_adjustment('subtract', $butterfly_cutoff_theoretical_value);

        # absolute difference between the two theo probabilities
        my $absolute_difference_of_theoretical_values = Math::Util::CalculatedValue::Validatable->new({
            name        => 'absoute_difference_of_theoretical_values',
            description => 'The absolute difference of theoretical values',
            set_by      => 'Role::StandardMarkup',
            base_amount => abs($actual_theoretical_value_amount - $butterfly_cutoff_theoretical_value_amount),
        });

        $absolute_difference_of_theoretical_values->include_adjustment('absolute', $difference_of_theoretical_values);
        $comm->include_adjustment('multiply', $absolute_difference_of_theoretical_values);
    }

    return $comm;
}

=head2 butterfly_cutoff_theoretical_value_amount

Returns the theo probability of the same bet, but with the vol surface
modified to reflect an ON butterfly equal to a specified butterfly_cutoff.

=cut

sub butterfly_cutoff_theoretical_value_amount {

    my ($self, $butterfly_cutoff) = @_;
    my $bet = $self->bet;

    # obtain a copy of the ON smile from the current surface
    my $surface_original  = $bet->volsurface;
    my $surface_copy_data = $surface_original->surface;
    my $first_tenor       = $surface_original->original_term_for_smile->[0];

# determine the new 25 and 75 vols based on the original surface's ATM and RR, and the new butterfly_cutoff
    my $bf_original  = $surface_original->get_market_rr_bf($first_tenor)->{BF_25};
    my $rr_original  = $surface_original->get_market_rr_bf($first_tenor)->{RR_25};
    my $atm_original = $surface_copy_data->{$first_tenor}->{smile}{50};
    my $c25_original = $surface_copy_data->{$first_tenor}->{smile}{25};
    my $c75_original = $surface_copy_data->{$first_tenor}->{smile}{75};
    my $bf_modified  = $butterfly_cutoff;
    my $c25_modified = $bf_modified + $atm_original + 0.5 * $rr_original;
    my $c75_modified = $c25_modified - $rr_original;

# genrate a new bet price based off of the modified surface, and insert the new 25 and 75 vols back into the smile
    my $surface_modified = $surface_original->clone();
    $surface_modified->surface->{$first_tenor}{smile}{25} = $c25_modified;
    $surface_modified->surface->{$first_tenor}{smile}{75} = $c75_modified;
    my $butterfly_cutoff_bet = BOM::Product::ContractFactory::make_similar_contract($bet, {volsurface => $surface_modified});

    return $butterfly_cutoff_bet->theo_probability->amount;
}

sub _build_spot_spread_markup {

    my $self = shift;

    my $ss_markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'spot_spread_markup',
        description => 'Reflects the spread in market bid-ask for the underlying',
        set_by      => __PACKAGE__,
        base_amount => 0,
        minimum     => 0,
        maximum     => 0.01,
    });

    my $bet_delta = Math::Util::CalculatedValue::Validatable->new({
        name        => 'bet_delta',
        description => 'The absolute value of delta of the priced option',
        set_by      => 'BOM::Product::Pricing::Engine::Role::MarketPricedPortfolios',
        base_amount => abs($self->bet->delta),
    });

    my $spot_spread = Math::Util::CalculatedValue::Validatable->new({
        name        => 'spot_spread',
        description => 'Underlying bid-ask spread',
        set_by      => 'BOM::Market::Underlying',
        base_amount => $self->bet->underlying->spot_spread,
    });

    $ss_markup->include_adjustment('reset',    $bet_delta);
    $ss_markup->include_adjustment('multiply', $spot_spread);

    return $ss_markup;
}

# Hard-coded values to interpolate against
# days => factor
my $dsp_interp = Math::Function::Interpolator->new(
    points => {
        0   => 1.5,
        1   => 1.5,
        10  => 1.2,
        20  => 1,
        365 => 1,
    });

=head2 risk_markup

Markup added to accommdate for pricing uncertainty

=cut

sub _build_risk_markup {
    my $self = shift;

    my $risk_markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'risk_markup',
        description => 'A set of markups added to accommodate for pricing risk',
        set_by      => __PACKAGE__,
        base_amount => 0,
    });
    if ($self->bet->market->markups->apply_traded_markets_markup) {
        $risk_markup->include_adjustment('add',      $self->vol_spread_markup);
        $risk_markup->include_adjustment('add',      $self->spot_spread_markup) if (not $self->bet->is_intraday);
        $risk_markup->include_adjustment('subtract', $self->forward_starting_markup);

        if (grep { $self->bet->market->name eq $_ } qw(forex stocks) and $self->bet->timeindays->amount < 7 and not $self->bet->is_atm_bet) {
            $risk_markup->include_adjustment('add', $self->smile_uncertainty_markup);
        }

        if (grep { $self->bet->market->name eq $_ } qw(forex commodities) and $self->bet->is_intraday) {
            $risk_markup->include_adjustment('add', $self->economic_events_markup);
        }

        $risk_markup->include_adjustment('add', $self->eod_market_risk_markup);
    }

    if ($self->bet->market->markups->apply_butterfly_markup) {
        $risk_markup->include_adjustment('add', $self->butterfly_markup);
    }

    my $spread_to_markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'spread_to_markup',
        description => 'Apply half of spread to each side',
        set_by      => __PACKAGE__,
        base_amount => 2,
    });

    $risk_markup->include_adjustment('divide', $spread_to_markup);

    return $risk_markup;
}

=head2 commission_markup

Fixed commission for the bet

=cut

sub _build_commission_markup {
    my $self = shift;

    my $bet = $self->bet;

    my $comm_markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'commission_markup',
        description => 'Fixed commission markup',
        set_by      => __PACKAGE__,
    });

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

    my $spread_to_markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'spread_to_markup',
        description => 'Apply half of spread to each side',
        set_by      => __PACKAGE__,
        base_amount => 2,
    });

    $comm_markup->include_adjustment('reset',    $comm_scale);
    $comm_markup->include_adjustment('multiply', $self->digital_spread_markup);
    $comm_markup->include_adjustment('divide',   $spread_to_markup);

    return $comm_markup;
}

sub _build_digital_spread_markup {
    my $self = shift;

    my $bet = $self->bet;

    my $dsm = Math::Util::CalculatedValue::Validatable->new({
        name        => 'digital_spread_markup',
        description => 'Intrinsic option spread',
        set_by      => __PACKAGE__,
        base_amount => 0,
    });

    my $comm_market = $self->commission_market;
    my $bet_type    = $self->commission_bet_type;
    my $level       = $self->commission_level;
    my $key         = join '.', ($comm_market, $bet_type);
    my $dsp_amount  = $self->bet->underlying->market->markups->digital_spread->{$bet_type} / 100;
    # this is added so that we match the commission of tick trades
    $dsp_amount /= 2 if $bet->timeinyears->amount * 86400 * 365 <= 20 and $bet->is_atm_bet;

    my $dsp = Math::Util::CalculatedValue::Validatable->new({
        name        => 'digital_spread_percentage',
        description => 'Base digital spread',
        set_by      => 'BOM::Market',
        base_amount => $dsp_amount,
    });

    my $level_multiplier = Math::Util::CalculatedValue::Validatable->new({
        name        => 'commission_level_multiplier',
        description => 'Multiplier for the underlying-specific risk level',
        set_by      => 'quants.commission.digital_spread.level_multiplier',
        base_amount =>
            BOM::Platform::Runtime->instance->app_config->quants->commission->digital_spread->level_multiplier**($self->commission_level - 1),
    });

    $dsp->include_adjustment('multiply', $level_multiplier);

    $dsm->include_adjustment('reset', $dsp);

    my $dsp_scaling = Math::Util::CalculatedValue::Validatable->new({
            name        => 'dsp_scaling',
            description => 'Scaling factor based on bet duration',
            set_by      => __PACKAGE__,
            base_amount => ($bet->market->name eq 'random')
            ? 1
            : $dsp_interp->linear($bet->timeindays->amount),
        });

    $dsm->include_adjustment('multiply', $dsp_scaling);

    return $dsm;
}

=head2 commission_market

Under which market do we look up commission values?

=cut

sub _build_commission_market {
    my $self = shift;

    my $market = $self->bet->underlying->market;

    # Equities covers multiple markets.
    my $commission_market = $self->bet->underlying->market->name;
    $commission_market = 'equities'
        if ($self->bet->underlying->market->equity);

    return $commission_market;
}

=head2 commission_bet_type

Under which bet type do we look up commission values?

=cut

sub _build_commission_bet_type {
    my $self = shift;

    my $bet = $self->bet;

    return
          (not $bet->is_path_dependent) ? 'european'
        : ($bet->two_barriers)          ? 'double_barrier'
        :                                 'single_barrier';
}

=head2 commission_level

Which commission level applies?

=cut

sub _build_commission_level {
    my $self = shift;

    return $self->bet->underlying->commission_level;
}

sub _build_forward_starting_markup {
    my $self = shift;

    my $bet = $self->bet;
    my $fs  = Math::Util::CalculatedValue::Validatable->new({
        name        => 'forward_start',
        description => 'Adjustment to price based on forward-startingness',
        set_by      => __PACKAGE__,
        minimum     => 0,
        maximum     => 0.02,
        base_amount => 0,
    });

    if ($bet->is_forward_starting) {
        my $is_fs = Math::Util::CalculatedValue::Validatable->new({
            name        => 'is_forward_starting',
            description => 'Adjustment because this is a forward-starting option',
            set_by      => 'quants.commission.adjustment.forward_start_factor',
            base_amount => (BOM::Platform::Runtime->instance->app_config->quants->commission->adjustment->forward_start_factor / 100),
        });
        $fs->include_adjustment('reset', $is_fs);
    }

    return $fs;
}

=head2 economic_events_markup

During a news event the market can make a sudden jump. When clients place
a straddle during this event, they can make a good profit. We need to increase
vol_spread during this event.

The commission added is based on the following:

- Impact of news events on applicable currencies during duration of bet and 15 minutes before.
This impact is defined throught the backoffice. We take the event with the highest impact.

This markup should be built respectively by its engine or it will take zero as default.

=cut

has economic_events_markup => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_economic_events_markup {
    my $self = shift;

    my $economic_events_markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'economic_events_markup',
        description => 'the maximum of spot or volatility risk markup of economic events',
        set_by      => __PACKAGE__,
        base_amount => 0,
    });

    return $economic_events_markup;
}

has _influential_currencies => (
    is      => 'ro',
    isa     => 'ArrayRef',
    default => sub { ['USD', 'AUD', 'CAD', 'CNY', 'NZD'] });

sub get_applicable_economic_events {
    my ($self, $start, $end) = @_;

    my $bet = $self->bet;

    my $news = BOM::MarketData::Fetcher::EconomicEvent->new->get_latest_events_for_period({
        from => $start,
        to   => $end
    });
    my @influential_currencies = @{$self->_influential_currencies};
    my @applicable_symbols = uniq($bet->underlying->quoted_currency_symbol, $bet->underlying->asset_symbol, @influential_currencies);
    my @applicable_news;

    foreach my $symbol (@applicable_symbols) {
        my @news = grep { $_->symbol eq $symbol } @$news;
        push @applicable_news, @news;
    }
    @applicable_news =
        sort { $a->release_date->epoch <=> $b->release_date->epoch } @applicable_news;

    return @applicable_news;
}

sub _build_economic_events_spot_risk_markup {
    my $self = shift;

    my $markup_base_amount = 0;
    my $bet                = $self->bet;
    my $secs_to_expiry     = $bet->get_time_to_expiry({from => $bet->effective_start})->seconds;
    if ($secs_to_expiry and $secs_to_expiry > 10) {
        my $start           = $bet->effective_start->minus_time_interval('20m');
        my $end             = $bet->effective_start->plus_time_interval($bet->get_time_to_expiry({from => $bet->effective_start})->seconds + 600);
        my @economic_events = $self->get_applicable_economic_events($start, $end);

        my @triangle_sum = (0) x ($self->_volatility_seasonality_step_size + 1);
        foreach my $event (@economic_events) {
            my $end_of_effect = $event->release_date->plus_time_interval('20m');
            my @triangle;
            my $scale = $event->get_scaling_factor($bet->underlying, 'spot');
            next if not defined $scale;
            my $x1                   = $event->release_date->epoch;
            my $x2                   = $end_of_effect->epoch;
            my $y1                   = $scale;
            my $y2                   = 0;
            my $triangle_slope       = ($y1 - $y2) / ($x1 - $x2);
            my $intercept            = $y1 - $triangle_slope * $x1;
            my $epsilon              = $secs_to_expiry / $self->_volatility_seasonality_step_size;
            my $t                    = $bet->effective_start->epoch;
            my $ten_minutes_in_epoch = $event->release_date->plus_time_interval('10m')->epoch;
            my $primary_sum          = (3 / 4 * $scale * 600) / $epsilon;
            my $primary_sum_index    = 0;

# for intervals between $bet->effective_start->epoch and $bet->date_expiry->epoch
            for (0 .. $self->_volatility_seasonality_step_size) {
                my $height = 0;
                $primary_sum_index++ if $t <= $x1;
                if ($t >= $ten_minutes_in_epoch and $t <= $x2) {
                    $height = $triangle_slope * $t + $intercept;
                }
                push @triangle, $height;
                $t += $epsilon;
            }

            if (    $bet->effective_start->epoch <= $ten_minutes_in_epoch
                and $bet->date_expiry->epoch >= $event->release_date->epoch - 600)
            {
                $primary_sum_index = min($primary_sum_index, scalar(@triangle) - 1);
                $triangle[$primary_sum_index] = $primary_sum;
            }

            for (0 .. $#triangle) {
                $triangle_sum[$_] = $triangle[$_]
                    if $triangle[$_] > $triangle_sum[$_];
            }
        }

        $markup_base_amount = sum(@triangle_sum) / $self->_volatility_seasonality_step_size;
    }

    my $spot_risk_markup = Math::Util::CalculatedValue::Validatable->new({
        name        => 'economic_events_spot_risk_markup',
        description => 'markup to account for spot risk of economic events',
        set_by      => __PACKAGE__,
        maximum     => 0.15,
        base_amount => $markup_base_amount,
    });

    return $spot_risk_markup;
}

# Generally for indices and stocks the minimum available tenor for smile is 30 days.
# We use this to price short term contracts, so adding a 5% markup for the volatility uncertainty.
sub _build_smile_uncertainty_markup {
    my $self = shift;

    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'smile_uncertainty_markup',
        description => 'markup to account for volatility uncertainty for short term contracts on indices and stocks',
        set_by      => __PACKAGE__,
        base_amount => 0.05,
    });
}

1;
