package BOM::Product::Pricing::Engine::Role::StandardMarkup;

=head1 NAME

BOM::Product::Pricing::Engine::Role::StandardMarkup

=head1 DESCRIPTION

A Moose role which provides a standard markup for exotic options.

=cut

use 5.010;
use Moose::Role;
requires 'bet';

use List::Util qw(first);
use Math::Function::Interpolator;

use BOM::Product::Pricing::Greeks::BlackScholes;
use Quant::Framework::VolSurface::Utils;
use Quant::Framework::EconomicEventCalendar;

has [
    qw(smile_uncertainty_markup butterfly_markup vol_spread_markup spot_spread_markup risk_markup forward_starting_markup economic_events_markup)] =>
    (
    is         => 'ro',
    isa        => 'Math::Util::CalculatedValue::Validatable',
    lazy_build => 1,
    );

has [qw(uses_dst_shifted_seasonality)] => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

has _volatility_seasonality_step_size => (
    is      => 'ro',
    isa     => 'Num',
    default => 100,
);

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
            set_by      => 'Quant::Framework::VolSurface',
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
        and $bet->timeindays->amount <= $surface->_ON_day                  # only apply butterfly markup to overnight contracts
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
        my $actual_theoretical_value_amount = $bet->pricing_engine->base_probability->amount;
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

    return $butterfly_cutoff_bet->pricing_engine->base_probability->amount;
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
        set_by      => 'Quant::Framework::Underlying',
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
        minimum     => 0,
        base_amount => 0,
    });
    if ($self->bet->market->markups->apply_traded_markets_markup) {
        $risk_markup->include_adjustment('add',      $self->vol_spread_markup);
        $risk_markup->include_adjustment('add',      $self->spot_spread_markup) if (not $self->bet->is_intraday);
        $risk_markup->include_adjustment('subtract', $self->forward_starting_markup);

        if (not $self->bet->is_atm_bet and grep { $self->bet->market->name eq $_ } qw(indices stocks) and $self->bet->timeindays->amount < 7) {
            $risk_markup->include_adjustment('add', $self->smile_uncertainty_markup);
        }
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
            base_amount => (BOM::System::Config::quants->{commission}->{adjustment}->{forward_start_factor} / 100),
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
