package BOM::Product::Pricing::Engine::Slope::Observed;

=head1 NAME

BOM::Product::Pricing::Engine::Slope::Observed

=head1 DESCRIPTION

A slope engine based on observing the slope at the strike directly from the surface.

=cut

use Carp qw(confess);
use Moose;
extends 'BOM::Product::Pricing::Engine::Slope';

sub _build_skew {
    my $self = shift;

    my $bet  = $self->bet;
    my $args = $bet->pricing_args;

    my $skew = $self->get_strike_slope({
        days   => $args->{t} * 365,
        strike => $args->{barrier1},
        spot   => $args->{spot},
        q_rate => $bet->q_rate,
        r_rate => $bet->r_rate,
    });

    my $skew_adjustment = Math::Util::CalculatedValue::Validatable->new({
        name        => 'vol_slope',
        description => 'strike_slope directly from the BOM::MarketData::VolSurface',
        set_by      => 'BOM::Product::Pricing::Engine::Slope::Observed',
        base_amount => $skew
    });

    return $skew_adjustment;
}

sub get_strike_slope {
    my ($self, $args) = @_;

    my $volsurface = $self->bet->volsurface;
    # Move by 0.5% of strike either way.
    my $epsilon = $volsurface->underlying->pip_size;

    $args->{strike} -= $epsilon;
    my $down_vol = $volsurface->get_volatility($args);

    $args->{strike} += 2 * $epsilon;
    my $up_vol = $volsurface->get_volatility($args);

    return ($up_vol - $down_vol) / (2 * $epsilon);
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
