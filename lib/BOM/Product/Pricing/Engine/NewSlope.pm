package BOM::Product::Pricing::Engine::NewSlope;

use 5.010;
use strict;
use warnings;

use List::Util qw(min max);
use Math::Business::BlackScholes::Binaries;
use Math::Business::BlackScholes::Binaries::Greeks::Vega;

use constant {
    REQUIRED_ARGS => [
        qw(contract_type spot strikes timeinyears quanto_rate mu iv payouttime_code q_rate r_rate slope priced_with is_forward_starting first_available_smile_term)
    ],
    ALLOWED_TYPES => {
        CALL        => 1,
        PUT         => 1,
        EXPIRYMISS  => 1,
        EXPIRYRANGE => 1
    },
    MARKUPS => {
        commodities => {
            apply_traded_markets_markup => 1,
            digital_spread              => 4,
        },
        forex => {
            apply_traded_markets_markup => 1,
            apply_butterfly_markup      => 1,
            digital_spread              => 3.5,
        },
        indices => {
            apply_traded_markets_markup => 1,
            digital_spread              => 4,
        },
        stocks => {
            apply_traded_markets_markup => 1,
            digital_spread              => 4,
        },
        sectors => {
            apply_traded_markets_markup => 1,
            digital_spread              => 4,
        },
        random => {
            digital_spread => 3,
        },
    },
};

sub probability {
    my $args = shift;

    my $err;
    my $required = REQUIRED_ARGS;
    if (grep { not defined $args->{$_} } @$required) {
        return default_probability_reference('Insufficient input to calculate probability');
    }

    my $allowed = ALLOWED_TYPES;
    if (not $allowed->{$args->{contract_type}}) {
        return default_probability_reference("Could not calculate probability for $args->{contract_type}");
    }

    my $probability;
    my $priced_with = $args->{priced_with};

    if ($priced_with eq 'numeraire') {
        $probability = _get_probability($args);
    } elsif ($priced_with eq 'quanto') {
        my $mu = $args->{r_rate} - $args->{q_rate};
        $probability = _get_probability({%$args, mu => $mu});
    } elsif ($priced_with eq 'base') {
        my $ct             = $args->{contract_type};
        my $mu             = $args->{r_rate} - $args->{q_rate};
        my $quanto_rate    = $args->{r_rate};
        my $numeraire_prob = _get_probability({
            %$args,
            mu          => $mu,
            quanto_rate => $quanto_rate
        });
        my $base_vanilla_prob = _get_probability({%$args, contract_type => 'vanilla_' . lc $ct});
        my $which_way = $ct eq 'CALL' ? 1 : -1;
        my $strike = $args->{strikes}->[0];
        $probability = ($numeraire_prob * $strike + $base_vanilla_prob * $which_way) / $args->{spot};
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
        my $discounted_probability = exp(-$args->{quanto_rate} * $args->{timeinyears});
        $prob = $discounted_probability - _two_barrier_prob($args);
    } else {
        my ($bs_formula, $vanilla_vega_formula) = map { my $name = $_ . lc $ct; \&$name }
            ('Math::Business::BlackScholes::Binaries::', 'Math::Business::BlackScholes::Binaries::Greeks::Vega::vanilla_');
        my @pricing_args    = map { ref $_ eq 'ARRAY' ? @{$args->{$_}} : $args->{$_} } qw(spot strikes timeinyears quanto_rate mu iv payouttime_code);
        my $bs_probability  = $bs_formula->(@pricing_args);
        my $slope_base      = $args->{is_forward_starting} ? 0 : $args->{contract_type} eq 'CALL' ? -1 : 1;
        my $vega            = $vanilla_vega_formula->(@pricing_args);
        my $skew_adjustment = $slope_base * $args->{slope} * $vega;
        # If the first available smile term is more than 3 days away and the contract is intraday,
        # we cannot accurately calculate the intraday slope. Hence we cap and floor the skew adjustment to 3%.
        $skew_adjustment = min(0.03, max($skew_adjustment, -0.03))
            if ($args->{first_available_smile_term} > 3 and $args->{timeinyears} * 365 > 1);
        $prob = $bs_probability + $skew_adjustment;
    }

    return $prob;
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
