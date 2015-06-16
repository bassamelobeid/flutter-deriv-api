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

    my $skew = $bet->volsurface->get_strike_slope({
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

no Moose;
__PACKAGE__->meta->make_immutable;
1;
