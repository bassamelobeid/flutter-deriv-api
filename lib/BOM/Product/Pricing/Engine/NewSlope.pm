package BOM::Product::Pricing::Engine::NewSlope;

use 5.010;
use strict;
use warnings;

use Storable qw(dclone);
use List::Util qw(min max);
use YAML::CacheLoader qw(LoadFile);
use Finance::Asset;
use Math::Function::Interpolator;
use Math::Business::BlackScholes::Binaries;
use Math::Business::BlackScholes::Binaries::Greeks::Vega;

use constant {
    REQUIRED_ARGS => [qw(contract_type spot strikes date_start date_expiry discount_rate mu iv payouttime_code q_rate r_rate slope priced_with)],
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

    my $underlying_config = Finance::Asset->instance->get_parameters_for($args->{underlying_symbol});
    my $market            = $underlying_config->{$args->{underlying_symbol}}->{market};
    if ($market eq 'forex') {
        $args->{timeinyears} = $ref->{market_convention}->{calculate_expiry}->($args->{date_start}, $args->{date_expiry});
    } else {
        $args->{timeinyears} = ($args->{date_expiry}->epoch - $args->{date_start}->epoch) / (86400 * 365);
    }

    $args->{timeindays} = $args->{timeinyears} * 365;
    $args->{is_forward_starting} = (time > $args->{date_start}->epoch) ? 1 : 0;

    my $ct          = lc $args->{contract_type};
    my $priced_with = $args->{priced_with};
    my $probability;

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

    my $markup_config   = LoadFile('markup_config.yml')->{$args->{market}};
    my $is_atm_contract = $args->{spot} != $args->{strikes}->[0] ? 0 : 1;
    my $is_intraday     = $args->{timeindays} < 1 ? 1 : 0;

    my $risk_markup = 0;
    if ($markup_config->{'traded_market_markup'}) {
        if ($args->{is_forward_starting}) {
            # Forcing risk markup to 3% due to complaints from Australian affiliates.
            $risk_markup = 0.03;
        } else {
            # 1. vol_spread_markup
            my $spread_type = $is_atm_contract ? 'atm' : 'max';
            my $vol_spread = $ref->{market_data}->{get_spread}->({
                sought_point => $spread_type,
                day          => $args->{timeindays},
            });
            my $bs_vega_formula = 'Math::Business::BlackScholes::Binaries::Greeks::Vega::' . $ct;
            $bs_vega_formula = \&$bs_vega_formula;
            my $bs_vega           = $bs_vega_formula->(_get_pricing_args(%$args));
            my $vol_spread_markup = $vol_spread * $bs_vega;
            $risk_markup += $vol_spread_markup;

            # spot_spread_markup
            if (not $is_intraday) {
                my $spot_spread_size = $underlying_config->{spot_spread_size} // 50;
                my $spot_spread_base = $spot_spread_size * $underlying_config->{pip_size};
                my $bs_delta_formula = 'Math::Business::BlackScholes::Binaries::Greeks::Delta::' . $ct;
                $bs_delta_formula = \&$bs_delta_formula;
                my $bs_delta           = $bs_delta_formula->(_get_pricing_args(%$args));
                my $spot_spread_markup = $spot_spread_base * $bs_delta;
                $risk_markup += $spot_spread_markup;
            }

            # economic_events_markup
            # if forex or commodities and $is_intraday
            if ($markup_config->{'economic_event_markup'} and $is_intraday) {
                my $eco_events_spot_risk_markup = $ref->{market_data}->{get_economic_events_impact};
                $risk_markup += $eco_events_spot_risk_markup;
            }

            # end of day market risk markup
            # This is added for uncertainty in volatilities during rollover period.
            # The rollover time for volsurface is set at NY 1700. However, we are not sure when the actual rollover
            # will happen. Hence we add a 5% markup to the price.
            # if forex or commodities and duration <= 3
            if ($markup_config->{'end_of_day_markup'} and $args->{timeindays} <= 3) {
                my $ny_1600 = $ref->{market_convention}->{get_rollover_time}->($args->{date_start})->minus_time_interval('1h');
                if ($ny_1600->is_before($args->{date_start}) or ($is_intraday and $ny_1600->is_before($args->{date_expiry}))) {
                    my $eod_market_risk_markup = 0.05;    # flat 5%
                    $risk_markup += $eod_market_risk_markup;
                }
            }

            # This is added for the high butterfly condition where the butterfly is higher than threshold (0.01),
            # then we add the difference between then original probability and adjusted butterfly probability as markup.
            if ($markup_config->{'butterfly_markup'} and $args->{timeindays} <= 7) {
                my $butterfly_cutoff = 0.01;
                my $original_surface = $ref->{market_data}->{get_volsurface}->($args->{underlying_symbol});
                my $first_term       = (sort { $a <=> $b } keys %$original_surface)[0];
                my $market_rr_bf     = $ref->{market_data}->{get_market_rr_bf}->($first_term);
                if ($ref->{market_data}->{has_overnight_vol} and $market_rr_bf->{BF_25} > $butterfly_cutoff) {
                    my $original_bf = $market_rr_bf->{BF_25};
                    my $original_rr = $market_rr_bf->{RR_25};
                    my ($atm, $c25, $c75) = map { $original_surface->{$first_term}{smile}{$_} } qw(50 25 75);
                    my $c25_mod             = $butterfly_cutoff + $atm + 0.5 * $original_rr;
                    my $c75_mod             = $c25 - $original_rr;
                    my $cloned_surface_data = dclone($original_surface);
                    $cloned_surface_data->{$first_term}{smile}{25} = $c25_mod;
                    $cloned_surface_data->{$first_term}{smile}{75} = $c75_mod;
                    my $vol_after_butterfly_adjustment = $ref->{market_data}->{get_volatility}->({
                            strike => $args->{strikes}->[0],
                            days   => $args->{timeindays},
                        },
                        $cloned_surface_data
                    );
                    my $butterfly_adjusted_prob = _get_probability({%$args, iv => $vol_after_butterfly_adjustment});
                    my $butterfly_markup = abs($probability - $butterfly_adjusted_prob);
                    $risk_markup += $butterfly_markup;
                }
            }

            # risk_markup divided equally on both sides.
            $risk_markup /= 2;
        }
    }

    # commission_markup
    my $commission_markup = 0.03;
    unless ($args->{is_forward_starting}) {
        my $comm_file        = LoadFile('commission.yml');
        my $commission_level = $comm_file->{commission_level}->{$args->{underlying_symbol}};
        my $dsp_amount = $comm_file->{digital_spread_base}->{$underlying_config->{$args->{underlying_symbol}}->{market}}->{$args->{contract_type}}
            // 0;
        $dsp_amount /= 100;
        # this is added so that we match the commission of tick trades
        $dsp_amount /= 2 if $args->{timeindays} * 86400 <= 20 and $is_atm_contract;
        # 1.4 is hard-coded level multiplier
        my $level_multiplier          = 1.4 * ($commission_level - 1);
        my $digital_spread_percentage = $dsp_amount * $level_multiplier;
        my $fixed_scaling             = $comm_file->{digital_spread_scaling}->{$args->{underlying_symbol}};
        my $dsp_interp                = Math::Function::Interpolator->new(
            points => {
                0   => 1.5,
                1   => 1.5,
                10  => 1.2,
                20  => 1,
                365 => 1,
            });
        my $dsp_scaling = $fixed_scaling || $dsp_interp->linear($args->{timeinyears});
        my $digital_spread_markup = $digital_spread_percentage * $dsp_scaling;
        $commission_markup = $digital_spread_markup / 2;
    }

    return {
        probability       => $probability,
        commission_markup => $commission_markup,
        risk_markup       => $risk_markup,
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
            if ($args->{first_available_smile_term} > 3 and $args->{timeindays} < 1);
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
