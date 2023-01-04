package BOM::Product::Contract::Strike::Vanilla;

use strict;
use warnings;

use POSIX     qw(ceil floor);
use Math::CDF qw( qnorm );

use List::Util            qw(max min);
use POSIX                 qw(ceil floor);
use Format::Util::Numbers qw/roundnear roundcommon/;
use Math::Round           qw(round);
use BOM::Config::Runtime;

=head2 SECONDS_IN_A_YEAR

How long is a 365 day year in seconds

=cut

use constant {SECONDS_IN_A_YEAR => 31536000};

=head2 roundup

round up a value
roundup(63800, 1000) = 64000

=cut

sub roundup {
    my ($value_to_round, $precision) = @_;

    $precision = 1 if $precision == 0;
    return ceil($value_to_round / $precision) * $precision;
}

=head2 rounddown

round down a value
roundown(63800, 1000) = 63000

=cut

sub rounddown {
    my ($value_to_round, $precision) = @_;

    $precision = 1 if $precision == 0;
    return floor($value_to_round / $precision) * $precision;
}

=head2 calculate_implied_strike

calculate strike price given delta

=cut

sub calculate_implied_strike {
    my $args = shift;

    my $spot  = $args->{current_spot};
    my $vol   = $args->{pricing_vol};
    my $t     = $args->{timeinyears};
    my $delta = $args->{delta};

    # This is for risk management,
    # the idea is that we define the allowed delta that we can accept,
    # and calculate the maximum/minimum Strike price from it
    #
    #                                            pnorm(d1) = Delta
    #                                                   d1 = qnorm(Delta)
    # (log(spot/strike) + ((vol**2)/2) * t) / vol*(t**0.5) = qnorm(Delta)
    #                (log(spot/strike) + ((vol**2)/2) * t) = qnorm(Delta) * vol*(t**0.5)
    #                                     log(spot/strike) = qnorm(Delta) * vol*(t**0.5) - ((vol**2)/2) * t)
    #                              log(spot) - log(strike) = qnorm(Delta) * vol*(t**0.5) - ((vol**2)/2) * t)
    #                                        - log(strike) = qnorm(Delta) * vol*(t**0.5) - ((vol**2)/2) * t) - log(spot)
    #                                          log(strike) = - qnorm(Delta) * vol*(t**0.5) + ((vol**2)/2) * t) + log(spot)
    #                                               strike = exp**(- qnorm(Delta) * vol*(t**0.5) + ((vol**2)/2) * t) + log(spot))

    my $strike_price = exp((-(qnorm($delta) * $vol * ($t**0.5)) + (($vol**2) / 2) * $t) + log($spot));

    return $strike_price;
}

=head2 strike_price_choices

Returns a range of strike price that is calculated from delta.

=cut

sub strike_price_choices {
    my $args = shift;

    my $ul           = $args->{underlying};
    my $is_intraday  = $args->{is_intraday};
    my $current_spot = $args->{current_spot};
    my $vol          = $args->{pricing_vol};

    my $symbol = $ul->symbol;
    my $expiry = $is_intraday ? 'intraday' : 'daily';

    my $expected_move    = $current_spot * $vol * ((60 / SECONDS_IN_A_YEAR)**0.5);
    my $number_of_digits = roundnear(1, (log(1 / $expected_move) / log(10))) - 1;

    $args->{expected_move}    = $expected_move;
    $args->{number_of_digits} = $number_of_digits;
    $args->{per_symbol_config} =
        JSON::MaybeXS::decode_json(BOM::Config::Runtime->instance->app_config->get("quants.vanilla.per_symbol_config.$symbol" . "_$expiry"));

    if ($is_intraday) {
        return intraday_strike_price_choices($args);
    }

    return daily_strike_price_choices($args);
}

=head2 intraday_strike_price_choices

calculate strike price choices for intraday

=cut

sub intraday_strike_price_choices {
    my $args = shift;

    my $current_spot      = $args->{current_spot};
    my $per_symbol_config = $args->{per_symbol_config};

    my @strike_price_choices;
    my $delta_array = $per_symbol_config->{delta_config};

    for my $delta (@{$delta_array}) {
        $args->{delta} = $delta;
        my $strike_price = calculate_implied_strike($args);
        $strike_price = $strike_price - $current_spot;
        $delta > 0.5 ? $strike_price = round($strike_price) : $strike_price = round($strike_price);   #round up when delta > 0.5, round down otherwise
        $strike_price = $strike_price >= 0 ? "+" . $strike_price : "" . $strike_price;
        push @strike_price_choices, $strike_price;
    }
    return \@strike_price_choices;
}

=head2 daily_strike_price_choices

calculate strike price choices for >intraday

=cut

sub daily_strike_price_choices {
    my $args = shift;

    my $ul                = $args->{underlying};
    my $per_symbol_config = $args->{per_symbol_config};
    my $number_of_digits  = $args->{number_of_digits};
    my $n_max             = $per_symbol_config->{max_strike_price_choice};
    my $factor            = $args->{factor} // 1;

    my @strike_price_choices;
    my $delta_array = $per_symbol_config->{delta_config};
    my $strike_step = $factor * 10**(-$number_of_digits);

    $args->{delta} = min @{$delta_array};
    my $max_strike = rounddown(calculate_implied_strike($args), 10**(-$number_of_digits));

    $args->{delta} = max @{$delta_array};
    my $min_strike = roundup(calculate_implied_strike($args), 10**(-$number_of_digits));

    my $number_of_available_strikes = int(($max_strike - $min_strike) / $strike_step) + 1;

    foreach my $n (1 .. $number_of_available_strikes) {
        push @strike_price_choices, roundcommon($ul->pip_size, $min_strike + $strike_step * ($n - 1));
    }

    if ($number_of_available_strikes > $n_max) {
        my $factor = ceil($number_of_available_strikes / $n_max);
        $args->{factor} = $factor;
        return daily_strike_price_choices($args);
    }

    return \@strike_price_choices;

}

1;
