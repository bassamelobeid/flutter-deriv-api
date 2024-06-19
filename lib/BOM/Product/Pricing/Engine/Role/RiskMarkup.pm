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
use BOM::Config;
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
        bet_vega   => abs($bet->vega),
        vol_spread => $bet->volsurface->get_spread({
                sought_point => 'max',
                day          => $bet->timeindays->amount
            }
        ),
    )->markup;
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
        $risk_markup->include_adjustment('add',      $self->vol_spread_markup)  if not $self->bet->is_atm_bet;
        $risk_markup->include_adjustment('add',      $self->spot_spread_markup) if (not $self->bet->is_intraday);
        $risk_markup->include_adjustment('subtract', $self->forward_starting_markup);

        if (not $self->bet->is_atm_bet and $self->bet->market->name eq 'indices' and $self->bet->timeindays->amount < 7) {
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
            base_amount => (BOM::Config::quants()->{commission}->{adjustment}->{forward_start_factor} / 100),
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
