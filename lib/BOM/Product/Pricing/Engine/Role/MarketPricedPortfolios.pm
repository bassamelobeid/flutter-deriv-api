package BOM::Product::Pricing::Engine::Role::MarketPricedPortfolios;

=head1 NAME

BOM::Product::Pricing::Engine::Role::MarketPricedPortfolios

=head1 DESCRIPTION

A Moose role which provides a set of portfolios around a given exotic.

=cut

use Moose::Role;

requires 'bet';

use Math::Cephes::Matrix qw(mat);
use Math::Business::BlackScholesMerton::Binaries;
use Math::Business::BlackScholesMerton::NonBinaries;

use BOM::Product::Pricing::Engine::BlackScholes;
use BOM::Product::Pricing::Greeks::BlackScholes;
use VolSurface::Utils qw(get_strike_for_spot_delta get_ATM_strike_for_spot_delta);

has [qw(priced_portfolios hedge_cost_matrix on_equities vol_spread vvv_matrix greek_market_prices bet_greeks hedge_tiy hedge_tid)] => (
    is         => 'ro',
    lazy_build => 1,
);

my %analytic_functions = (
    VANILLA_CALL => \&Math::Business::BlackScholesMerton::NonBinaries::vanilla_call,
    VANILLA_PUT  => \&Math::Business::BlackScholesMerton::NonBinaries::vanilla_put,
);

my %greek_functions = (
    VANILLA_CALL => {
        vega  => \&Math::Business::BlackScholes::Binaries::Greeks::Vega::vanilla_call,
        vanna => \&Math::Business::BlackScholes::Binaries::Greeks::Vanna::vanilla_call,
        volga => \&Math::Business::BlackScholes::Binaries::Greeks::Volga::vanilla_call,
    },
    VANILLA_PUT => {
        vega  => \&Math::Business::BlackScholes::Binaries::Greeks::Vega::vanilla_put,
        vanna => \&Math::Business::BlackScholes::Binaries::Greeks::Vanna::vanilla_put,
        volga => \&Math::Business::BlackScholes::Binaries::Greeks::Volga::vanilla_put,
    },
);

# Building the 3 available portfolios, Butterfly, ATM straddle and Risk Reversal)

has [qw(portfolios)] => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        return {
            butterfly => {
                options => [{
                        type  => 'VANILLA_PUT',
                        units => 0.5,
                        delta => 25
                    },
                    {
                        type  => 'VANILLA_CALL',
                        units => 0.5,
                        delta => 25
                    },
                    {
                        type  => 'VANILLA_CALL',
                        units => -0.5,
                        delta => 50,
                    },
                    {
                        type  => 'VANILLA_PUT',
                        units => -0.5,
                        delta => 50,
                    }
                ],
            },
            risk_reversal => {
                options => [{
                        type  => 'VANILLA_CALL',
                        units => 1,
                        delta => 25
                    },
                    {
                        type  => 'VANILLA_PUT',
                        units => -1,
                        delta => 25
                    }
                ],
            },
            atm => {
                options => [{
                        type  => 'VANILLA_CALL',
                        units => 0.5,
                        delta => 50,
                    },
                    {
                        type  => 'VANILLA_PUT',
                        units => 0.5,
                        delta => 50,
                    },
                ],
            }};
    });

# This sub returns the ATM vol spread. This will eventually be used to determine our bid-ask spread using the method suggested in [1]. But as of now it is used for wystup's correction weight formula.

sub _build_vol_spread {
    my $self = shift;

# In actual use we want half of this number, but it's easier to name and understand in this way.
# bid_vol = mid_vol - (vol_spread / 2)
# ask_vol = mid_vol + (vol_spread / 2)

    return $self->bet->volsurface->get_spread({
        sought_point => 'atm',
        day          => $self->hedge_tid->amount
    });

}

=head2 bet_greeks

Greeks for our supplied exotic option (bet)

=cut 

sub _build_bet_greeks {
    my ($self) = @_;

    my $bet = $self->bet;
    return {map { $_ => $bet->$_ } qw(delta vega vanna volga)};
}

=head2 Get cost per unit of Greeks.

We create a 3x3 square matrix, which would have the vega, vanna and volga of the three known portfolios - ATM straddle, RR and BF.

Thus,
                                   |ATM(vega)      RR(vega)     BF(vega) |
                     A =           |ATM(vanna)     RR(vanna)    BF(vanna)|
                                   |ATM(volga)     RR(volga)    BF(volga)|

                     w =           | w(ATM)|
                                   | w(RR) |
                                   | w(BF) |

                     x =           | X(vega) |
                                   | X(vanna)|
                                   | X(volga)|

                     y =           | ATM(market) - ATM(BS)|          |Y(atm)|
                                   | RR(market)  - RR(BS) |     =    |Y(RR) |
                                   | BF(market)  - BF(BS) |          |Y(BF) |


We know that from the above matrices, we have :    Aw = x .........................(1)

Now we also know that : Market Price = BS Price + p * w' * y ......................(2)

where p = correction weights
      w'= Transpose of w

Combining equations (1) and (2) we get :
      Market price = BS Price + p * (A_inverse * x)' * y
                   = BS Price + p * x' * (A')_inverse * y
                   = BS Price + p * x' * v
Where v = (A')_inverse * y, is the vector of market prices of vega, vanna and volga (Cost per unit of Greeks). Its entries correspond to the premium that must be attached to these greeks in order to adjust the Black Scholes price of the ATM, RR and BF instruments to the market price of those instruments. As a full matrix equation, this becomes :

            |ATM(vega) ATM(vanna) ATM(volga)|  |v(vega) |   =  |Y(atm)|
            |RR(vega)  RR(vanna)  RR(volga) |  |v(vanna)|   =  |Y(RR) |
            |BF(vega)  BF(vanna)  BF(volga) |  |v(volga)|   =  |Y(BF) |


=cut

sub _build_greek_market_prices {
    my $self = shift;

    my $A      = $self->vvv_matrix;
    my $y      = $self->hedge_cost_matrix;
    my $result = $A->transp->simq($y);

    return {
        vega  => ($self->on_equities) ? 0 : $result->[0],
        vanna => $result->[1],
        volga => ($self->on_equities) ? 0 : $result->[2],
    };
}

=head2 vvv_matrix

Greeks for our portfolios in matrix form

=cut

sub _build_vvv_matrix {
    my $self = shift;

    my @matrix_rows;

    foreach my $greek (qw(vega vanna volga)) {
        push @matrix_rows,
            [
            map { $self->priced_portfolios->{$_}->{greeks}->{$greek} }
            sort keys %{$self->priced_portfolios}];
    }

    return mat(\@matrix_rows);
}

=head2 hedge_cost_matrix

This builds the hedge cost matrix, which is actually a matrix of (Market Cost - BS cost) for the selected portfolio.

=cut

sub _build_hedge_cost_matrix {
    my $self = shift;

    return [map { $self->priced_portfolios->{$_}->{cost} } sort keys %{$self->priced_portfolios}];
}

sub _build_priced_portfolios {
    my $self = shift;

    my %priced_portfolios;

    my $from    = $self->bet->effective_start;
    my $to      = $self->bet->date_expiry;
    my $atm_vol = $self->bet->volsurface->get_volatility({
        from  => $from,
        to    => $to,
        delta => 50,
    });

    foreach my $portfolio_name (keys %{$self->portfolios}) {
        $priced_portfolios{$portfolio_name} = $self->portfolio_hedge($portfolio_name, $atm_vol, $from, $to);
    }

    return \%priced_portfolios;
}

=head1 METHODS

=head2 portfolio_hedge

Determine the hedge for a given portfolio name for the given ATM vol and expiry days. This actually does market price - BS price to get the hedge.

=cut

sub portfolio_hedge {
    my ($self, $portfolio_name, $atm_vol, $from, $to) = @_;

    my $bet       = $self->bet;
    my $portfolio = $self->portfolios->{$portfolio_name};

    my $mu               = $bet->mu;
    my $discount_rate    = $bet->discount_rate;
    my $hedge_tiy        = $self->hedge_tiy->amount;
    my $r_rate           = $bet->r_rate;
    my $q_rate           = $bet->q_rate;
    my $S                = $bet->pricing_spot;
    my $premium_adjusted = $bet->underlying->{market_convention}->{delta_premium_adjusted};

    my %values = (
        cost   => 0,
        greeks => {
            vanna => 0,
            volga => 0,
            vega  => 0,
        },
    );

    foreach my $option (@{$portfolio->{options}}) {
        my $delta = $option->{delta};

        my $vv_vol = $bet->volsurface->get_volatility({
            from  => $from,
            to    => $to,
            delta => ($option->{type} eq 'VANILLA_CALL' ? $delta : 100 - $delta),
        });

        my $strike =
            ($delta == 50)
            ? get_ATM_strike_for_spot_delta({
                atm_vol          => $atm_vol,
                t                => $hedge_tiy,
                r_rate           => $r_rate,
                q_rate           => $q_rate,
                spot             => $S,
                premium_adjusted => $premium_adjusted
            })
            : get_strike_for_spot_delta({
                delta            => $delta / 100,
                option_type      => $option->{type},
                atm_vol          => $atm_vol,
                t                => $hedge_tiy,
                r_rate           => $r_rate,
                q_rate           => $q_rate,
                spot             => $S,
                premium_adjusted => $premium_adjusted
            });

        my $function = $analytic_functions{uc $option->{type}};

        $values{cost} +=
            $option->{units} *
            (
            $function->($S, $strike, $hedge_tiy, $discount_rate, $mu, $vv_vol) - $function->($S, $strike, $hedge_tiy, $discount_rate, $mu, $atm_vol));

        $values{spread} +=
            $option->{units} *
            ($function->($S, $strike, $hedge_tiy, $discount_rate, $mu, $vv_vol + ($self->vol_spread / 2)) -
                $function->($S, $strike, $hedge_tiy, $discount_rate, $mu, $atm_vol - ($self->vol_spread / 2)));

        foreach my $greek (keys %{$values{greeks}}) {
            my $value = 0;

            # On equities we only consider the Vanna of the risk-reversal portfolio.
            my $function = $greek_functions{uc $option->{type}}->{$greek};
            if (not $self->on_equities
                or ($portfolio_name eq 'risk_reversal' and $greek eq 'vanna'))
            {
                $value = $option->{units} * ($function->($S, $strike, $hedge_tiy, $discount_rate, $mu, $vv_vol));

            }
            $values{greeks}->{$greek} += $value;
        }
    }

    if ($self->on_equities) {
        if ($portfolio_name eq 'atm') {
            $values{greeks}->{vega} = 1;
        } elsif ($portfolio_name eq 'butterfly') {
            $values{greeks}->{volga} = 1;
        }
    }

    return \%values;
}

sub _build_hedge_tiy {
    my $self = shift;

    return $self->bet->timeinyears;
}

sub _build_hedge_tid {
    my $self = shift;

    return $self->bet->timeindays;
}

sub _build_on_equities {
    my $self = shift;

    return $self->bet->underlying->market->equity;
}

1;
