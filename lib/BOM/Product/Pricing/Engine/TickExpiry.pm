package BOM::Product::Pricing::Engine::TickExpiry;

use 5.010;
use strict;
use warnings;

use Scalar::Util qw(looks_like_number);
use Cache::RedisDB;
use List::Util qw(sum min max);
use YAML::CacheLoader qw(LoadFile);
use Date::Utility;

use constant {
    REQUIRED_ARGS => [qw(contract_type underlying_symbol last_twenty_ticks economic_events)],
    ALLOWED_TYPES => {
        CALL => 1,
        PUT  => 1
    },
};

sub bs_probability {
    # there's nothing much to be done here.
    return {
        probability => 0.5,
        debug_info  => {},
        markups     => {
            model_markup      => 0,
            commission_markup => 0,
            risk_markup       => 0,
        },
        error => undef,
    };
}

sub probability {
    my $args = shift;

    # input check
    my $required = REQUIRED_ARGS;
    if (grep { not defined $args->{$_} } @$required) {
        return _default_probability_reference('Insufficient input to calculate probability');
    }

    my $allowed = ALLOWED_TYPES;
    if (not $allowed->{$args->{contract_type}}) {
        return _default_probability_reference("Could not calculate probability for $args->{contract_type}");
    }

    my $err;
    my ($contract_type, $ticks, $economic_events, $underlying_symbol) =
        @{$args}{'contract_type', 'last_twenty_ticks', 'economic_events', 'underlying_symbol'};

    # We allow date_pricing as a parameter for bpot
    my $date_pricing = $args->{date_pricing} // Date::Utility->new;
    my $affected_by_economic_events = @$economic_events ? 1 : 0;
    my %debug_information = (
        affected_by_economic_events => $affected_by_economic_events,
    );

    my ($vol_proxy, $trend_proxy);
    ($vol_proxy, $trend_proxy, $err) = _get_proxy($ticks, $date_pricing);
    $debug_information{base_vol_proxy} = $vol_proxy;
    $debug_information{base_trend_proxy} = $trend_proxy;

    my $coef = _coefficients()->{$underlying_symbol};

    # coefficient sanity check
    my @required_coef = qw(x_prime_min x_prime_max y_min y_max A B C D tie_A tie_B tie_C tie_D);
    if (grep { not defined $coef->{$_} or not looks_like_number($coef->{$_}) } @required_coef) {
        return _default_probability_reference('Invalid coefficients for probability calculation');
    }
    $debug_information{coefficients} = $coef;

    my $x_min = $coef->{x_prime_min};
    my $x_max = $coef->{x_prime_max};
    my $y_min = $coef->{y_min};
    my $y_max = $coef->{y_max};

    $vol_proxy = min($y_max, max($y_min, $vol_proxy));
    $debug_information{vol_proxy} = $vol_proxy;
    $trend_proxy = min($x_max, max($x_min, $trend_proxy));
    $debug_information{trend_proxy} = $trend_proxy;

    # calculates trend adjustment
    # A,B,C,D are paramters that defines the pricing "surface".  The values are obtained emperically.
    my $f1               = $coef->{A} * sqrt($vol_proxy) + $coef->{B} * $vol_proxy + $coef->{C};
    my $f2               = 1 + exp($coef->{D} * $trend_proxy);
    my $trend_adjustment = $f1 * (1 / $f2 - 0.5);
    $debug_information{trend_adjustment} = $trend_adjustment;

    # probability
    my $base_probability = bs_probability()->{probability};
    my $probability = $contract_type eq 'PUT' ? $base_probability - $trend_adjustment : $base_probability + $trend_adjustment;
    $probability = min(1, max(0.5, $probability));

    # risk_markup
    my $tie_adjustment = ($coef->{tie_A} * $trend_proxy**2 + $coef->{tie_B} + $coef->{tie_C} * $vol_proxy + $coef->{tie_D} * sqrt($vol_proxy)) / 2;
    $debug_information{tie_adjustment} = $tie_adjustment;
    # do not discount if the contract is affected by economic events.
    my $tie_factor = $affected_by_economic_events ? 0 : 0.75;
    $debug_information{tie_factor} = $tie_factor;
    my $risk_markup = -$tie_adjustment * $tie_factor;
    $debug_information{base_risk_markup} = $risk_markup;

    if (   ($debug_information{base_trend_proxy} > $x_max)
        or ($debug_information{base_trend_proxy} < $x_min)
        or ($debug_information{base_vol_proxy} > $y_max)
        or ($debug_information{base_vol_proxy} < $y_min))
    {
        $risk_markup += 0.03;
    }
    # maximum discount is 10%
    $risk_markup = max(-0.1, $risk_markup);
    $debug_information{risk_markup} = $risk_markup;

    # commission_markup
    my $commission_markup = 0.025;
    $debug_information{commission_markup} = $commission_markup;

    # model_markup
    my $model_markup = $risk_markup + $commission_markup;
    $debug_information{model_markup} = $model_markup;

    return {
        probability => $probability,
        debug_info  => \%debug_information,
        markups     => {
            model_markup      => $model_markup,
            commission_markup => $commission_markup,
            risk_markup       => $risk_markup,
        },
        error => $err,
    };
}

# Having this as a private subroutine for testability
sub _get_proxy {
    my ($ticks, $date_pricing) = @_;

    my ($vol_proxy, $trend_proxy, $err);
    if (@$ticks and @$ticks == 20 and abs($date_pricing->epoch - $ticks->[0]->{epoch}) < 300) {
        my $sum = sum(map { log($ticks->[$_]->{quote} / $ticks->[$_ - 1]->{quote})**2 } (1 .. 19));
        $vol_proxy = sqrt($sum / 19);
    } else {
        $vol_proxy = 0.20;                                                 # 20% volatility
        $err       = 'Do not have enough ticks to calculate volatility';
    }

    if (not $err) {
        my $ma_step = 7;
        my $avg     = sum(map { $_->{quote} } @$ticks[-$ma_step .. -1]) / $ma_step;
        my $x       = ($ticks->[-1]{quote} - $avg) / $ticks->[-1]{quote};
        # it is quite impossible for vol_proxy to be 0. Let's not die if it is!
        $trend_proxy = $x / $vol_proxy if $vol_proxy != 0;
    } else {
        $trend_proxy = 0;
    }

    return ($vol_proxy, $trend_proxy, $err);
}

sub _coefficients {
    return LoadFile('/home/git/regentmarkets/bom/config/files/tick_trade_coefficients.yml');
}

sub _default_probability_reference {
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
