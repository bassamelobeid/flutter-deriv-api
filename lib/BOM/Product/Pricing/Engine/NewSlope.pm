package BOM::Product::Pricing::Engine::NewSlope;

use 5.010;
use strict;
use warnings;

use List::Util qw(min max);
use Math::Business::BlackScholes::Binaries;
use Math::Business::BlackScholes::Binaries::Greeks;

use constant {
    REQUIRED_ARGS => [
        qw(contract_type spot strikes timeinyears quanto_rate mu iv payouttime_code q_rate r_rate slope) #volatility_spread is_forward_starting first_available_smile_term priced_with)
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

    my ($bs_formula, $vanilla_formula) =
        map { my $str = 'Math::Business::BlackScholes::Binaries::' . lc $_; \&$str; } ($args->{contract_type}, 'vanilla_' . $args->{contract_type});

    my $probability;
    if ($args->{contract_type} eq 'EXPIRYMISS') {
        $probability = _two_barrier_prob($args);
    } elsif ($args->{contract_type} eq 'EXPIRYRANGE') {
        $probability = exp(-$args->{quanto_rate} * $args->{timeinyears}) - _two_barrier_prob($args);
    } elsif ($args->{priced_with} ne 'base') {
        # TODO: min max for bs probability
        my @pricing_args =
            ($args->{spot}, @{$args->{strikes}}, $args->{timeinyears}, $args->{quanto_rate}, $args->{mu}, $args->{iv}, $args->{payouttime_code});
        my $bs_probability  = $bs_formula->(@pricing_args);
        my $slope_base      = $args->{is_forwarding_starting} ? 0 : $args->{contract_type} eq 'CALL' ? -1 : 1;
        my $vanilla_vega    = Math::Business::BlackScholes::Binaries::Greeks::vega(@pricing_args);
        my $skew_adjustment = $slope_base * $args->{slope} * $vanilla_vega;
        # If the first available smile term is more than 3 days away and the contract is intraday,
        # we cannot accurately calculate the intraday slope. Hence we cap and floor the skew adjustment to 3%.
        my $day_in_year = 0.00273972602;
        $skew_adjustment = min(0.03, max($skew_adjustment, -0.03)) if ($args->{first_available_smile_term} > 3 and $args->{timeinyears} * 365 > $day_in_year);
        $probability = $bs_probability + $skew_adjustment;
    } elsif ($args->{priced_with} eq 'base') {
        my %cloned_args = %$args;
        # convert quanto_rate and mu to numeraire
        $cloned_args{quanto_rate} = $args->{r_rate};
        $cloned_args{mu}          = $args->{r_rate} - $args->{q_rate};
        $cloned_args{priced_with} = 'numeraire';
        my $numeraire_probability    = probability(\%cloned_args);
        my $base_vanilla_probability = $vanilla_formula->(
            $args->{spot}, @{$args->{strikes}},
            $args->{timeinyears}, $args->{quanto_rate}, $args->{mu}, $args->{iv}, $args->{payouttime_code});
        my $which_way = $args->{contract_type} eq 'CALL' ? 1 : -1;
        $probability = $numeraire_probability * $args->{strikes}->[0] + $base_vanilla_probability * $which_way / $args->{spot};
    }

    return $probability;
}

sub _two_barrier_prob {
    my $args = shift;

    my $strikes = $args->{strikes};
    my ($high_strike, $low_strike) = $strikes->[0] > $strikes->[1] ? ($strikes->[0], $strikes->[1]) : ($strikes->[1], $strikes->[0]);
    my %call_args = (
        %$args,
        contract_type => 'CALL',
        strikes       => $high_strike
    );
    my %put_args = (
        %$args,
        contract_type => 'PUT',
        strikes       => $low_strike
    );
    my $probability = probability(\%call_args) + probability(\%put_args);

    return $probability;
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
