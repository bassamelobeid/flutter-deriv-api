package BOM::Product::Pricing::Engine::Intraday;

=head1 NAME

BOM::Product::Pricing::Engine::Intraday

=head1 DESCRIPTION

Price digital options with current realized vols and adjustments

=cut

use Moose;
extends 'BOM::Product::Pricing::Engine';
with 'BOM::Product::Pricing::Engine::Role::StandardMarkup';

use Math::Function::Interpolator;

use BOM::Market::AggTicks;
use List::Util qw(max);
use BOM::Platform::Context qw(request localize);
use Format::Util::Numbers qw( roundnear );
use Time::Duration::Concise;

=head2 tick_source

The source of the ticks used for this pricing.  BOM::Market::AggTicks

=cut

has tick_source => (
    is      => 'ro',
    default => sub { BOM::Market::AggTicks->new },
);

has [qw(period_opening_value period_closing_value long_term_vol)] => (
    is         => 'ro',
    lazy_build => 1,
);

## PRIVATE ##

has [qw(_vol_interval _trend_interval)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__vol_interval {
    my $self = shift;

    my $bet_seconds = roundnear(1, $self->bet->timeindays->amount * 86400);

    return Time::Duration::Concise->new(interval => max(900, $bet_seconds));
}

sub _build__trend_interval {
    my $self = shift;

    my $bet_seconds = roundnear(1, $self->bet->timeindays->amount * 86400);

    return Time::Duration::Concise->new(interval => max(120, $bet_seconds));
}

=head2 long_term_vol

The long_term vol used to compute vega and constrain our intraday historical vol.

Presently represent the 1W tenor.  Math::Util::CalculatedValue::Validatable.

=cut

sub _build_long_term_vol {
    my $self = shift;

    return Math::Util::CalculatedValue::Validatable->new({
            name        => 'long_term_vol',
            description => 'long term (1 week) vol)',
            set_by      => __PACKAGE__,
            base_amount => $self->bet->volsurface->get_volatility({
                    delta => 50,
                    days  => 7
                }
            ),
        });
}

sub _formula_args {
    my $self = shift;

    my $bet  = $self->bet;
    my $args = $bet->pricing_args;
    my @barrier_args =
          ($bet->two_barriers)
        ? ($args->{barrier1}, $args->{barrier2})
        : ($args->{barrier1});

    return ($args->{spot}, @barrier_args, $args->{t}, 0, 0, $self->pricing_vol, $args->{payouttime_code});
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
