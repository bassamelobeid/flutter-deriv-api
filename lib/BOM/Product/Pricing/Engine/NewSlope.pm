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

    my ($bs_formula, $vanilla_formula, $vanilla_vega_formula) = map { my $name = $_ . lc $args->{contract_type}; \&$name } (
        'Math::Business::BlackScholes::Binaries::',
        'Math::Business::BlackScholes::Binaries::vanilla_',
        'Math::Business::BlackScholes::Binaries::Greeks::Vega::vanilla_'
    );

    my ($probability, %debug_information);
    if ($args->{contract_type} eq 'EXPIRYMISS') {
        $probability = _two_barrier_prob($args);
    } elsif ($args->{contract_type} eq 'EXPIRYRANGE') {
        $probability = exp(-$args->{quanto_rate} * $args->{timeinyears}) - _two_barrier_prob($args);
    } elsif ($args->{priced_with} ne 'base') {
        # TODO: min max for bs probability
        my @pricing_args =
            ($args->{spot}, @{$args->{strikes}}, $args->{timeinyears}, $args->{quanto_rate}, $args->{mu}, $args->{iv}, $args->{payouttime_code});
        my $bs_probability = $debug_information{bs_probability} = $bs_formula->(@pricing_args);
        my $slope_base = $args->{is_forwarding_starting} ? 0 : $args->{contract_type} eq 'CALL' ? -1 : 1;
        my $vega = $debug_information{vanilla_vega} = $vanilla_vega_formula->(@pricing_args);
        my $skew_adjustment = $slope_base * $args->{slope} * $vega;
        $debug_information{base_skew_adjustment} = $skew_adjustment;
        # If the first available smile term is more than 3 days away and the contract is intraday,
        # we cannot accurately calculate the intraday slope. Hence we cap and floor the skew adjustment to 3%.
        $skew_adjustment = $debug_information{skew_adjustment} = min(0.03, max($skew_adjustment, -0.03))
            if ($args->{first_available_smile_term} > 3 and $args->{timeinyears} * 365 * 86400 > 86400);
        $probability = $bs_probability + $skew_adjustment;
    } elsif ($args->{priced_with} eq 'base') {
        my %cloned_args = %$args;
        # To price a base with Slope pricer, we need the numeraire probability.
        # Convert quanto_rate and mu to numeraire. Not the most elegant solution.
        $cloned_args{quanto_rate} = $args->{r_rate};
        $cloned_args{mu}          = $args->{r_rate} - $args->{q_rate};
        $cloned_args{priced_with} = 'numeraire';
        my $numeraire_prob_ref = probability(\%cloned_args);
        my $numeraire_probability = $debug_information{numeraire_probability} = $numeraire_prob_ref->{probability};
        $debug_information{$_} = $numeraire_prob_ref->{debug_info}->{$_} for keys %{$numeraire_prob_ref->{debug_info}};
        my $strike                   = $args->{strikes}->[0];
        my $base_vanilla_probability = $debug_information{vanilla_price} =
            $vanilla_formula->($args->{spot}, $strike,
            $args->{timeinyears}, $args->{quanto_rate}, $args->{mu}, $args->{iv}, $args->{payouttime_code});
        my $which_way = $args->{contract_type} eq 'CALL' ? 1 : -1;
        $probability = ($numeraire_probability * $strike + $base_vanilla_probability * $which_way) / $args->{spot};
    }

    return {
        probability => $probability,
        debug_info  => \%debug_information,
    };
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
