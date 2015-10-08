package BOM::Product::Pricing::Engine::NewSlope;

use 5.010;
use strict;
use warnings;

use Storable qw(dclone);
use List::Util qw(min max);
use Math::Business::BlackScholes::Binaries;
use Math::Business::BlackScholes::Binaries::Greeks::Vega;

use constant {
    REQUIRED_ARGS => [
        qw(contract_type spot strikes timeinyears discount_rate mu iv payouttime_code q_rate r_rate slope priced_with is_forward_starting first_available_smile_term)
    ],
    ALLOWED_TYPES => {
        CALL        => 1,
        PUT         => 1,
        EXPIRYMISS  => 1,
        EXPIRYRANGE => 1
    },
};

sub probability {
    my ($args, $ref) = @_;

    my $err;
    my $required = REQUIRED_ARGS;
    if (grep { not defined $args->{$_} } @$required) {
        return default_probability_reference('Insufficient input to calculate probability');
    }

    my $allowed = ALLOWED_TYPES;
    if (not $allowed->{$args->{contract_type}}) {
        return default_probability_reference("Could not calculate probability for $args->{contract_type}");
    }

    my $ct = lc $args->{contract_type};
    my $probability;
    my $priced_with = $args->{priced_with};

    if ($priced_with eq 'numeraire') {
        $probability = _get_probability($args);
    } elsif ($priced_with eq 'quanto') {
        my $mu = $args->{r_rate} - $args->{q_rate};
        $probability = _get_probability({%$args, mu => $mu});
    } elsif ($priced_with eq 'base') {
        my $mu             = $args->{r_rate} - $args->{q_rate};
        my $discount_rate  = $args->{r_rate};
        my $numeraire_prob = _get_probability({
            %$args,
            mu            => $mu,
            discount_rate => $discount_rate,
        });
        my $base_vanilla_prob = _get_probability({%$args, contract_type => 'vanilla_' . $ct});
        my $which_way = $ct eq 'call' ? 1 : -1;
        my $strike = $args->{strikes}->[0];
        $probability = ($numeraire_prob * $strike + $base_vanilla_prob * $which_way) / $args->{spot};
    }

    my ($risk_markup, $commission_markup) = (0) x 2;
    if ($ref->{market_config}->apply_traded_markets_markup) {
        if ($args->{is_forward_starting}) {
            # Forcing risk and commission markup to 3% due to complaints from Australian affiliates.
            ($risk_markup, $commission_markup) = (0.03) x 2;
        } else {
            my $is_atm_contract = $args->{spot} != $args->{strikes}->[0] ? 0 : 1;
            my $is_intraday     = $args->{timeinyears} * 365 < 1         ? 1 : 0;

            # 1. vol_spread_markup
            my $spread_type = $is_atm_contract ? 'atm' : 'max';
            my $vol_spread = $ref->{market_data}->{get_spread}->({
                sought_point => $spread_type,
                day          => $args->{timeinyears} * 365
            });
            my $bs_vega_formula = 'Math::Business::BlackScholes::Binaries::Greeks::Vega::' . $ct;
            $bs_vega_formula = \&$bs_vega_formula;
            my $bs_vega           = $bs_vega_formula->(_get_pricing_args(%$args));
            my $vol_spread_markup = $vol_spread * $bs_vega;
            $risk_markup += $vol_spread_markup;

            # spot_spread_markup
            unless ($is_intraday) {
                my $spot_spread_base = $ref->{market_data}->{get_spot_spread};
                my $bs_delta_formula = 'Math::Business::BlackScholes::Binaries::Greeks::Delta::' . $ct;
                $bs_delta_formula = \&$bs_delta_formula;
                my $bs_delta           = $bs_delta_formula->(_get_pricing_args(%$args));
                my $spot_spread_markup = $spot_spread_base * $bs_delta;
                $risk_markup += $spot_spread_markup;
            }

            # economic_events_markup
            # if forex or commodities and $is_intraday
            if ($ref->{market_config}->apply_economic_events_markup and $is_intraday) {
                my $eco_events_spot_risk_markup = $ref->{market_data}->{get_economic_events_impact};
                $risk_markup += $eco_events_spot_risk_markup;
            }

            # end of day market risk markup
            # This is added for uncertainty in volatilities during rollover period.
            # The rollover time for volsurface is set at NY 1700. However, we are not sure when the actual rollover
            # will happen. Hence we add a 5% markup to the price.
            # if forex or commodities and duration <= 3
            if ($ref->{market_config}->apply_end_of_day_markup) {
                my $eod_market_risk_markup = 0.05;    # flat 5%
                $risk_markup += $eod_market_risk_markup;
            }

            # This is added for the high butterfly condition where the butterfly is higher than threshold (0.01),
            # then we add the difference between then original probability and adjusted butterfly probability as markup.
            if ($ref->{market_config}->apply_butterfly_markup) {
                my $butterfly_cutoff = 0.01;
                my $original_surface = $ref->{market_data}->{get_volsurface}->($args->{underlying_symbol});
                my $first_term       = (sort { $a <=> $b } keys %$original_surface)[0];
                my $market_rr_bf     = $ref->{market_data}->{get_market_rr_bf}->($first_term);
                my $original_bf      = $market_rr_bf->{BF_25};
                my $original_rr      = $market_rr_bf->{RR_25};
                my ($atm, $c25, $c75) = map { $original_surface->{$first_term}{smile}{$_} } qw(50 25 75);
                my $c25_mod             = $butterfly_cutoff + $atm + 0.5 * $original_rr;
                my $c75_mod             = $c25 - $original_rr;
                my $cloned_surface_data = dclone($original_surface);
                $cloned_surface_data->{$first_term}{smile}{25} = $c25_mod;
                $cloned_surface_data->{$first_term}{smile}{75} = $c75_mod;
                my $vol_after_butterfly_adjustment = $ref->{market_data}->{get_volatility}->({
                        strike => $args->{strikes}->[0],
                        days   => $args->{timeinyears} * 365
                    },
                    $cloned_surface_data
                );
                my $butterfly_adjusted_prob = _get_probability({%$args, iv => $vol_after_butterfly_adjustment});
                my $butterfly_markup = abs($probability - $butterfly_adjusted_prob);
                $risk_markup += $butterfly_markup;
            }

            # risk_markup divided equally on both sides.
            $risk_markup /= 2;
        }
    }

    return {
        probability => $probability,
    };
}

sub _get_probability {
    my $args = shift;

    my $prob;
    my $ct = $args->{contract_type};

    if ($ct eq 'EXPIRYMISS') {
        $prob = _two_barrier_prob($args);
    } elsif ($ct eq 'EXPIRYRANGE') {
        my $discounted_probability = exp(-$args->{discount_rate} * $args->{timeinyears});
        $prob = $discounted_probability - _two_barrier_prob($args);
    } else {
        my ($bs_formula, $vanilla_vega_formula) = map { my $name = $_ . lc $ct; \&$name }
            ('Math::Business::BlackScholes::Binaries::', 'Math::Business::BlackScholes::Binaries::Greeks::Vega::vanilla_');
        my @pricing_args    = _get_pricing_args(%$args);
        my $bs_probability  = $bs_formula->(@pricing_args);
        my $slope_base      = $args->{is_forward_starting} ? 0 : $args->{contract_type} eq 'CALL' ? -1 : 1;
        my $vega            = $vanilla_vega_formula->(@pricing_args);
        my $skew_adjustment = $slope_base * $args->{slope} * $vega;
        # If the first available smile term is more than 3 days away and the contract is intraday,
        # we cannot accurately calculate the intraday slope. Hence we cap and floor the skew adjustment to 3%.
        $skew_adjustment = min(0.03, max($skew_adjustment, -0.03))
            if ($args->{first_available_smile_term} > 3 and $args->{timeinyears} * 365 < 1);
        $prob = $bs_probability + $skew_adjustment;
    }

    return $prob;
}

sub _get_pricing_args {
    my %args = @_;

    my @pricing_args = map { ref $args{$_} eq 'ARRAY' ? @{$args{$_}} : $args{$_} } qw(spot strikes timeinyears discount_rate mu iv payouttime_code);

    return @pricing_args;
}

sub _two_barrier_prob {
    my $args = shift;

    my ($low_strike, $high_strike) = sort { $a <=> $b } @{$args->{strikes}};
    my $call_prob = _get_probability({
            %$args,
            contract_type => 'CALL',
            strikes       => [$high_strike]});
    my $put_prob = _get_probability({
            %$args,
            contract_type => 'PUT',
            strikes       => [$low_strike]});

    return $call_prob + $put_prob;
}

sub default_probability_reference {
    my $err = shift;

    return {
        probability => 1,
        debug_info  => undef,
        markups     => {
            model_markup      => 0,
            commission_markup => 0,
            risk_markup       => 0,
        },
        error => $err,
    };
}
1;
