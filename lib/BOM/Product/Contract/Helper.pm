package BOM::Product::Contract::Helper;

use strict;
use warnings;

use BOM::Platform::Runtime;
use BOM::Platform::Static::Config;
use List::Util qw(max min);

# static definition of the commission slope
my $commission_base_multiplier = 1;
my $commission_max_multiplier  = 2;
my $commission_min_std         = 500;
my $commission_max_std         = 25000;
my $commission_slope           = ($commission_max_multiplier - $commission_base_multiplier) / ($commission_max_std - $commission_min_std);

sub commission_multiplier {
    my ($payout, $theo_probability) = @_;

    my $std = $payout * sqrt($theo_probability * (1 - $theo_probability));

    return $commission_base_multiplier if $std <= $commission_min_std;
    return $commission_max_multiplier  if $std >= $commission_max_std;

    my $slope      = $commission_slope;
    my $multiplier = ($std - $commission_min_std) * $slope + 1;

    return $multiplier;
}

sub commission {
    my $args = shift;

    die "you need to provide theo_probability and risk_markup and base_commission to calculate commission."
        if not(exists $args->{theo_probability} and exists $args->{base_commission});

    if (defined $args->{payout}) {
        return $args->{base_commission} * commission_multiplier($args->{payout}, $args->{theo_probability});
    }

    if (defined $args->{stake}) {
        die 'you need to provide risk_markup to calculate commission from stake' if not exists $args->{risk_markup};

        my ($theo_prob, $risk_markup, $base_commission, $ask_price) = @{$args}{'theo_probability', 'risk_markup', 'base_commission', 'stake'};

        delete $args->{base_commission};
        $args->{commission} = $base_commission;

        # payout calculated with base commission.
        my $initial_payout = calculate_payout($args);
        if (commission_multiplier($initial_payout, $theo_prob) == $commission_base_multiplier) {
            # a minimum of 2 cents please, payout could be zero.
            my $minimum_commission = $initial_payout ? 0.02 / $initial_payout : 0.02;
            return max($minimum_commission, $base_commission);
        }

        $args->{commission} = $base_commission * 2;
        # payout calculated with 2 times base commission.
        $initial_payout = calculate_payout($args);
        if (commission_multiplier($initial_payout, $theo_prob) == $commission_max_multiplier) {
            return $base_commission * 2;
        }

        my $a = $base_commission * $commission_slope * sqrt($theo_prob * (1 - $theo_prob));
        my $b = $theo_prob + $risk_markup + $base_commission - $base_commission * $commission_min_std * $commission_slope;
        my $c = -$ask_price;

        # sets it to zero first.
        $initial_payout = 0;
        for my $w (1, -1) {
            my $estimated_payout = (-$b + $w * sqrt($b**2 - 4 * $a * $c)) / (2 * $a);
            if ($estimated_payout > 0) {
                $initial_payout = $estimated_payout;
                last;
            }
        }

        # die if we could not get a positive payout value.
        die 'Could not calculate a payout' unless $initial_payout;

        return $base_commission * commission_multiplier($initial_payout, $theo_prob);
    }

    die 'Stake or payout is required to calculate commission.';
}

#A multiplicative factor which adjusts the model_markup.  This scale factor must be in the range [0.01, 5].
sub global_commission_adjustment {
    my $self = shift;

    my $minimum        = BOM::Platform::Static::Config::quants->{commission}->{adjustment}->{minimum} / 100,
        my $maximum    = BOM::Platform::Static::Config::quants->{commission}->{adjustment}->{maximum} / 100,
        my $adjustment = BOM::Platform::Runtime->instance->app_config->quants->commission->adjustment->global_scaling / 100;

    return min(max($adjustment, $minimum), $maximum);
}

sub calculate_payout {
    my $args = shift;

    return $args->{stake} / ($args->{theo_probability} + ($args->{risk_markup} + $args->{commission}) * global_commission_adjustment());
}

sub calculate_ask_probability {
    my $args = shift;

    my ($theo_probability, $risk_markup, $commission_markup, $market_supplement, $bs_probability, $probability_threshold, $pricing_engine_name) =
        @{$args}{qw(theo_probability risk_markup commission_markup market_supplement bs_probability probability_threshold pricing_engine_name)};

    # The below is a pretty unacceptable way to acheive this result. You do that stuff at the
    # Engine level.. or work it into your markup.  This is nonsense.
    my $minimum;
    if ($pricing_engine_name eq 'Pricing::Engine::TickExpiry') {
        $minimum = 0.4;
    } elsif ($pricing_engine_name eq 'BOM::Product::Pricing::Engine::Intraday::Index') {
        $minimum = 0.5 + $risk_markup + $commission_markup;
    } else {
        $minimum = $theo_probability;
    }

    my $maximum         = 1;
    my $ask_probability = $theo_probability + ($risk_markup + $commission_markup) * global_commission_adjustment();
    my $min_threshold   = $probability_threshold;
    my $max_threshold   = 1 - $probability_threshold;

    if ($ask_probability < $min_threshold) {
        $ask_probability = $min_threshold;
    } elsif ($ask_probability > $max_threshold) {
        $ask_probability = $maximum;
    }

    # final sanity check
    $ask_probability = max(min($ask_probability, $maximum), $minimum);

    # If BS is very high, we don't want that business, even if it makes sense.
    # Also, if the market supplement would absolutely drive us out of [0,1]
    # Then it is nonsense to be ignored.
    if (   $bs_probability >= 0.999
        || abs($market_supplement) >= 1
        || $market_supplement <= -0.5)
    {
        $ask_probability = $maximum;
    }

    return $ask_probability;
}

1;
