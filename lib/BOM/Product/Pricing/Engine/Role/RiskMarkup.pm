package BOM::Product::Pricing::Engine::Role::RiskMarkup;

=head1 NAME

BOM::Product::Pricing::Engine::Role::RiskMarkup

=head1 DESCRIPTION

A Moose role which provides a standard markup for exotic options.

=cut

use 5.010;
use Moose::Role;
requires 'bet';

use List::Util qw(first);
use Math::Function::Interpolator;

use BOM::Product::Pricing::Greeks::BlackScholes;
use BOM::Platform::Config;
use Quant::Framework::VolSurface::Utils;
use Quant::Framework::EconomicEventCalendar;

use Pricing::Engine::Markup::SpotSpread;
use Pricing::Engine::Markup::VolSpread;
use Pricing::Engine::Markup::SmileUncertainty;

has [qw(risk_markup forward_starting_markup)] => (
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

sub vol_spread_markup {
    my $self = shift;

    my $bet = $self->bet;
    return Pricing::Engine::Markup::VolSpread->new(
        bet_vega   => $bet->vega,
        vol_spread => $bet->volsurface->get_spread({
                sought_point => 'max',
                day          => $bet->timeindays->amount
            }
        ),
    )->markup;
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
    my $rr_original  = $surface_original->get_market_rr_bf($first_tenor)->{RR_25};
    my $atm_original = $surface_copy_data->{$first_tenor}->{smile}{50};
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

sub spot_spread_markup {
    my $self      = shift;
    my $ss_markup = Pricing::Engine::Markup::SpotSpread->new(
        bet_delta   => $self->bet->delta,
        spot_spread => $self->bet->underlying->spot_spread,
    );
    return $ss_markup->markup;
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
        $risk_markup->include_adjustment('add', $self->vol_spread_markup)  if not $self->bet->is_atm_bet;
        $risk_markup->include_adjustment('add', $self->spot_spread_markup) if (not $self->bet->is_intraday);
        $risk_markup->include_adjustment('subtract', $self->forward_starting_markup);

        if (not $self->bet->is_atm_bet and grep { $self->bet->market->name eq $_ } qw(indices stocks) and $self->bet->timeindays->amount < 7) {
            $risk_markup->include_adjustment('add', $self->smile_uncertainty_markup);
        }
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
            base_amount => (BOM::Platform::Config::quants->{commission}->{adjustment}->{forward_start_factor} / 100),
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

sub economic_events_markup {
    my $self = shift;

    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'economic_events_markup',
        description => 'the maximum of spot or volatility risk markup of economic events',
        set_by      => __PACKAGE__,
        base_amount => 0,
    });
}

sub smile_uncertainty_markup {
    my $self = shift;

    return Pricing::Engine::Markup::SmileUncertainty->new->markup;
}

1;
