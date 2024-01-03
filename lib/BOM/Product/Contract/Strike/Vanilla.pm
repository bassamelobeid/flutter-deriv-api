package BOM::Product::Contract::Strike::Vanilla;

use strict;
use warnings;

use POSIX     qw(ceil floor);
use Math::CDF qw( qnorm );

use List::Util            qw(max min);
use List::MoreUtils       qw(uniq);
use Format::Util::Numbers qw/roundnear roundcommon/;
use Math::Round           qw(round);
use BOM::Config::Runtime;
use BOM::Product::Utils qw(roundup rounddown);
use BOM::MarketData     qw(create_underlying);
use VolSurface::Utils   qw(get_strike_for_spot_delta);
use BOM::MarketData::Fetcher::VolSurface;
use Number::Closest::XS qw(find_closest_numbers_around);

=head2 SECONDS_IN_A_YEAR

How long is a 365 day year in seconds

=cut

use constant {SECONDS_IN_A_YEAR => 31536000};

=head2 strike_price_choices

Returns a range of strike price that is calculated from delta.

=cut

sub strike_price_choices {
    my $args = shift;

    my $ul           = $args->{underlying};
    my $is_intraday  = $args->{is_intraday};
    my $current_spot = $args->{current_spot};
    my $vol          = $args->{pricing_vol};
    my $trade_type   = $args->{trade_type} // 'VANILLALONGCALL';

    $args->{trade_type} = $trade_type =~ s/LONG/_/r;

    my $symbol             = $ul->symbol;
    my $expiry             = $is_intraday ? 'intraday' : 'daily';
    my $is_synthetic_index = $ul->market->name eq 'synthetic_index';

    my $expected_move = $current_spot * $vol * ((60 / SECONDS_IN_A_YEAR)**0.5);
    $expected_move = $current_spot * $vol * ((10 / SECONDS_IN_A_YEAR)**0.5) unless ($is_synthetic_index);
    my $number_of_digits = roundnear(1, (log(1 / $expected_move) / log(10))) - 1;

    $args->{expected_move}    = $expected_move;
    $args->{number_of_digits} = $number_of_digits;
    $args->{current_spot}     = roundnear(10**(-$args->{number_of_digits}), $args->{current_spot});
    $args->{per_symbol_config} =
        $is_synthetic_index
        ? JSON::MaybeXS::decode_json(BOM::Config::Runtime->instance->app_config->get("quants.vanilla.per_symbol_config.$symbol" . "_$expiry"))
        : JSON::MaybeXS::decode_json(BOM::Config::Runtime->instance->app_config->get("quants.vanilla.fx_per_symbol_config.$symbol"));

    # we only offer intraday vanilla options for synthetic indices
    return intraday_strike_price_choices($args) if ($is_intraday and $is_synthetic_index);
    return daily_strike_price_choices($args);
}

=head2 intraday_strike_price_choices

calculate strike price choices for intraday

=cut

sub intraday_strike_price_choices {
    my $args = shift;

    my $ul                = $args->{underlying};
    my $current_spot      = $args->{current_spot};
    my $per_symbol_config = $args->{per_symbol_config};

    my @strike_price_choices;
    my $delta_array = $per_symbol_config->{delta_config};

    for my $delta (@{$delta_array}) {
        my $volsurface_args = {
            delta            => $delta,
            option_type      => $args->{trade_type},
            atm_vol          => $args->{pricing_vol},
            t                => $args->{timeinyears},
            r_rate           => 0,
            q_rate           => 0,
            spot             => $args->{current_spot},
            premium_adjusted => 0
        };

        my $strike_price = get_strike_for_spot_delta($volsurface_args);
        $strike_price = roundnear($ul->pip_size * 10, ($strike_price - $current_spot));
        $strike_price = roundcommon($ul->pip_size, $strike_price);
        $strike_price = $strike_price >= 0 ? "+" . $strike_price : "" . $strike_price;

        push @strike_price_choices, $strike_price;
    }

    @strike_price_choices = uniq(@strike_price_choices);
    @strike_price_choices = sort { $b <=> $a } @strike_price_choices;

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

    my @strike_price_choices;
    my $delta_array = $per_symbol_config->{delta_config};

    my $is_synthetic_index = $ul->market->name eq 'synthetic_index';
    my $volsurface         = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $ul});
    my $closest_term       = find_closest_numbers_around($args->{timeinyears} * 365, $volsurface->original_term_for_smile, 2);

    my $volsurface_args = {
        delta            => (min @{$delta_array}),
        option_type      => $args->{trade_type},
        atm_vol          => $args->{pricing_vol},
        t                => $args->{timeinyears},
        r_rate           => 0,
        q_rate           => 0,
        spot             => $args->{current_spot},
        premium_adjusted => 0
    };

    unless ($is_synthetic_index) {
        my $volsurface_ul = create_underlying($ul->symbol);

        # using VANILLA_CALL so that the strike price choices are more stable
        $volsurface_args = {
            delta            => (min @{$delta_array}),
            option_type      => 'VANILLA_CALL',
            atm_vol          => $volsurface->get_surface_volatility($closest_term->[0], 10),
            t                => $args->{timeinyears},
            r_rate           => $volsurface_ul->interest_rate_for($args->{timeinyears}),
            q_rate           => $volsurface_ul->dividend_rate_for($args->{timeinyears}),
            spot             => $args->{current_spot},
            premium_adjusted => $volsurface_ul->{market_convention}->{delta_premium_adjusted}};
    }

    my $max_strike = get_strike_for_spot_delta($volsurface_args);

    $volsurface_args->{delta}   = (max @{$delta_array});
    $volsurface_args->{atm_vol} = $volsurface->get_surface_volatility($closest_term->[0], 90);
    my $min_strike = get_strike_for_spot_delta($volsurface_args);

    # we will have issue where min_strike > max_strike for puts
    ($max_strike, $min_strike) = ($min_strike, $max_strike) if $min_strike > $max_strike;

    $max_strike = rounddown($max_strike, 10**(-$number_of_digits));
    $min_strike = roundup($min_strike, 10**(-$number_of_digits));

    ($min_strike, $max_strike) = ($max_strike, $min_strike) if $min_strike > $max_strike;

    my $central_strike = roundnear(10**(-$number_of_digits), $args->{current_spot});

    my $adjusted_n = ($n_max - 3) / 2;
    my $strike_step_one;
    my $strike_step_two;

    if ($is_synthetic_index) {
        # rounding this to stabilize strike price flickering problem
        $strike_step_one = roundnear(10, ($central_strike - $min_strike) / ($adjusted_n + 1));
        $strike_step_two = roundnear(10, ($max_strike - $central_strike) / ($adjusted_n + 1));
    } else {
        $strike_step_one = ($central_strike - $min_strike) / ($adjusted_n + 1);
        $strike_step_two = ($max_strike - $central_strike) / ($adjusted_n + 1);
    }

    push @strike_price_choices, roundcommon($ul->pip_size, $central_strike);
    push @strike_price_choices, roundcommon($ul->pip_size, $min_strike);
    push @strike_price_choices, roundcommon($ul->pip_size, $max_strike);

    foreach my $n (1 .. $adjusted_n) {
        my $strike_price = $min_strike + $strike_step_one * $n;
        push @strike_price_choices, roundcommon($ul->pip_size, $strike_price);
    }

    foreach my $n (1 .. $adjusted_n) {
        my $strike_price = $central_strike + $strike_step_two * $n;
        push @strike_price_choices, roundcommon($ul->pip_size, $strike_price);
    }

    @strike_price_choices = sort { $a <=> $b } @strike_price_choices;
    @strike_price_choices = uniq(@strike_price_choices);
    return \@strike_price_choices;
}

1;
