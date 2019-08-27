package BOM::Product::Role::BarrierBuilder;

use Moose::Role;
use Try::Tiny;
use List::Util qw(max);
use Scalar::Util::Numeric qw(isint);
use VolSurface::Utils qw( get_strike_for_spot_delta );

use BOM::Product::Static;

my $ERROR_MAPPING = BOM::Product::Static::get_error_mapping();

has initial_barrier => (
    is  => 'rw',
    isa => 'Maybe[BOM::Product::Contract::Strike]',
);

sub make_barrier {
    my ($self, $supplied, $extra_params) = @_;

    my $string_version = $supplied;

    if (not defined $string_version) {
        $string_version = $self->underlying->pip_size;
        $self->_add_error({
            severity          => 100,
            message           => 'Undefined barrier',
            message_to_client => [$ERROR_MAPPING->{InvalidBarrierUndef}],
            details           => {field => $extra_params->{barrier_kind} eq 'low' ? 'barrier2' : 'barrier'},
        });
    }

    if (    $self->underlying->market->integer_barrier
        and not $self->for_sale
        and $string_version !~ /^S-?\d+P$/i
        and not isint($string_version))
    {
        $self->_add_error({
            severity          => 100,
            message           => 'Barrier is not an integer',
            message_to_client => [$ERROR_MAPPING->{IntegerBarrierRequired}],
            details           => {field => $extra_params->{barrier_kind} eq 'low' ? 'barrier2' : 'barrier'},
        });
    }

    # for volatlity indices, we allow absolute and relative barriers for tick expiry contracts
    if ($self->tick_expiry and $self->pricing_new and $string_version !~ /^S-?\d+P|[-+]\d+(\.\d+)?$/i and $self->underlying->market->name ne 'volidx')
    {
        $self->_add_error({
            severity          => 100,
            message           => 'Intend to buy tick expiry contract with absolute barrier.',
            message_to_client => [$ERROR_MAPPING->{InvalidBarrier}],
            details           => {field => $extra_params->{barrier_kind} eq 'low' ? 'barrier2' : 'barrier'},
        });
    }

    my $barrier = BOM::Product::Contract::Strike->new(
        underlying       => $self->underlying,
        basis_tick       => $self->_basis_tick,
        supplied_barrier => $string_version,
        %$extra_params,,
    );

    return $barrier;
}

has minimum_allowable_move => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_minimum_allowable_move {
    my $self = shift;

    my $duration_in_minutes = $self->timeindays->amount * 24 * 60;
    my $min_move;

    if ($duration_in_minutes >= 10) {
        $min_move = 2;
    } else {
        my $atm_vol = $self->volsurface->get_volatility({
            from                    => $self->effective_start,
            to                      => $self->date_expiry,
            $self->volsurface->type => $self->volsurface->atm_spread_point,
        });

        # The line defined below represents the boundary in delta of strike versus time space where we
        # don't feel comfortable offering PD contracts.
        # E.g. For a 5-minute contract, we don't feel comfortable offering PD contracts with a delta of strike between 49 and 51.
        # As the duration increases, the range of disallowed delta of strikes decreases down to a minimum of 2 pips.
        # Note: Rates are set to zero so that the boundary of offered PD contracts is symmetric around the Spot.
        my $min_delta_slope     = -1 / 75;
        my $min_delta_intercept = 173 / 300;
        my $duration_in_minutes = $self->timeindays->amount * 24 * 60;
        my $min_delta           = max($min_delta_slope * $duration_in_minutes + $min_delta_intercept, 0.5);
        my $min_strike          = get_strike_for_spot_delta({
            delta => ($min_delta >= 0.5) ? 1 - $min_delta : $min_delta,
            option_type      => 'VANILLA_CALL',
            atm_vol          => $atm_vol,
            t                => $self->timeinyears->amount,
            spot             => $self->current_spot,
            r_rate           => 0,
            q_rate           => 0,
            premium_adjusted => $self->underlying->{market_convention}->{delta_premium_adjusted},
        });

        # represents the minimum number of pips that the strike must move for a valid bet
        $min_move = $self->underlying->pipsized_value($min_strike - $self->current_spot) / $self->underlying->pip_size;
    }

    return $min_move;
}

sub _apply_barrier_adjustment {
    my ($self, $barrier) = @_;

    # We need to shift barriers for path dependent contracts to account for the discrete
    # nature of the ticks.  For now, only on volindices, because we know the tick frequency and
    # have very very short term PD contracts.
    # We introduced a concept of barrier shift in pricing our barrier contracts. So now we shift the barrier away from the current spot by a factor.
    # This factor is an empirical number, that is estimated by reducing the errors between the continuous pricing model and the true discrete price.
    # The true value of a discrete barrier option can be found by numerical methods, which is a very intensive process.
    #  We don't want to indulge in that as we need fast prices and numerical methods may not converge fast enough for our automated system.
    # So the best solution is to estimate a continuous price such that its error is minimum to the true value. Broadie, Glasserman and Kou estimate this in their paper "http://www.columbia.edu/~sk75/mfBGK.pdf".
    #  This shift comes out to be : exp(0.5826 * vol * sqrt(delT))
    # Here, delT = barrier monitoring interval (so for example, as we generate a volidx tick every 2 seconds right now, dltT = 2/60/60/24/365).
    # The number 0.5826 is a rough estimation of : 0.5826 ~ eta(0.5) / sqrt(2*pi), where eta = Riemann zeta function (this is available on page 327 of the above mentioned paper).
    # So if the barrier is above the spot, new barrier for pricing = barrier * exp(0.5826 * vol * sqrt(delT))
    # and when it is below the barrier, new barrier = barrier / exp(0.5826 * vol * sqrt(delT))
    # Hence this always makes the OT and Double OTs cheaper and the NT and DNT more expensive. This looks counter intuitive, but it is not.
    # Consider a OT. So imagine a case when we are missing all the ticks between the bet start and bet end. In that case, it is equivalent to a European digital option.
    # Now we know that approximately, OT = 2 * Digital, hence in this case because of missing ticks we are charging almost twice as much as we should be doing in an ideal world.
    # Hence we need to discount the price to account for the fact that we are missing ticks. So a barrier shift away from the spot would make the OTs cheaper and would account for this.
    # So another way of looking at it is as a seller of an option, missing ticks is great if we are just selling OTs but very bad for the NTs.
    # So we need a shift that would adjust for this while monitoring barriers discretely by increasing the price of NT / DNTs and decreasing the price for OT/DOTs.

    if ($self->market->name eq 'volidx' and $self->is_path_dependent) {
        my $used_vol            = $self->pricing_vol;
        my $generation_interval = $self->underlying->submarket->generation_interval->days / 365;
        my $dir                 = ($barrier > $self->current_spot) ? 1 : -1;                       # Move in same direction from spot.
        my $shift               = exp($dir * 0.5826 * $used_vol * sqrt($generation_interval));
        $barrier *= $shift;
    }

    return $barrier;
}

1;
