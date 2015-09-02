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

=head2 chunk_count

How many sub-chunks to use for vol computation.

=cut

has chunk_count => (
    is      => 'ro',
    default => 1
);

=head2 tick_source

The source of the ticks used for this pricing.  BOM::Market::AggTicks

=cut

has tick_source => (
    is      => 'ro',
    default => sub { BOM::Market::AggTicks->new },
);

has [qw(period_opening_value period_closing_value ticks_for_trend long_term_vol)] => (
    is         => 'ro',
    lazy_build => 1,
);

## PRIVATE ##

has [qw(_vol_interval _trend_interval)] => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 period_opening_value

The first tick of our aggregation period, reenvisioned as a Math::Util::CalculatedValue::Validatable

=cut

sub _build_period_opening_value {
    my $self = shift;

    return $self->ticks_for_trend->{first};
}

=head2 period_closing_value

The final tick of our aggregation period, reenvisioned as a Math::Util::CalculatedValue::Validatable.

For contracts which we are pricing now, it's the latest spot.

=cut

sub _build_period_closing_value {
    my $self = shift;

    return $self->ticks_for_trend->{last};
}

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

sub _build_ticks_for_trend {
    my $self = shift;

    my $bet        = $self->bet;
    my $underlying = $bet->underlying;
    my $at         = $self->tick_source;
    my $how_long   = $self->_trend_interval;

    my @unchunked_ticks = @{
        $at->retrieve({
                underlying   => $underlying,
                interval     => $how_long,
                ending_epoch => $bet->date_pricing->epoch,
                fill_cache   => !$bet->backtest,
            })};

    my ($iov, $icv) = (@unchunked_ticks) ? ($unchunked_ticks[0]{value}, $unchunked_ticks[-1]{value}) : ($bet->current_spot, $bet->current_spot);
    my $iot = Math::Util::CalculatedValue::Validatable->new({
        name        => 'period_opening_value',
        description => 'First tick in intraday aggregated ticks',
        set_by      => __PACKAGE__,
        base_amount => $iov,
    });

    my $ict = Math::Util::CalculatedValue::Validatable->new({
        name        => 'period_closing_value',
        description => 'Last tick in intraday aggregated ticks',
        set_by      => __PACKAGE__,
        base_amount => $icv,
    });

    return +{
        first => $iot,
        last  => $ict
    };
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
