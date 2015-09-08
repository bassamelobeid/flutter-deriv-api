package BOM::Product::Pricing::Engine::TickExpiry;

use 5.010;
use strict;
use warnings;

use Cache::RedisDB;
use List::MoreUtils qw(uniq);
use List::Util qw(sum min max);
use YAML::XS qw(Load);
use YAML::CacheLoader qw(LoadFile);
use Date::Utility;

use constant {
    REQUIRED_ARGS => [qw(contract_type underlying_symbol last_twenty_ticks economic_events)],
    ALLOWED_TYPES => [qw(CALL PUT)],
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
    my $err;
    my @required = (REQUIRED_ARGS);
    if (grep { not $args->{$_} } @required) {
        $err = 'Insufficient input to calculate probability';
    }

    my %allowed = map { $_ => 1 } (ALLOWED_TYPES);
    if (not $allowed{$args->{contract_type}}) {
        $err = "Could not calculate probability for $args->{contract_type}";
    }

    my ($contract_type, $ticks, $economic_events, $underlying_symbol) =
        @{$args}{'contract_type', 'last_twenty_ticks', 'economic_events', 'underlying_symbol'};

    # We allow date_pricing as a parameter for bpot
    my $date_pricing = $args->{date_pricing} // Date::Utility->new;
    my $coef = LoadFile('/home/git/regentmarkets/bom/config/files/tick_trade_coefficients.yml')->{$underlying_symbol};

    my $affected_by_economic_events = @$economic_events ? 1 : 0;
    my %debug_information = (
        affected_by_economic_events => $affected_by_economic_events,
    );

    my $x_min = $coef->{x_prime_min};
    my $x_max = $coef->{x_prime_max};
    my $y_min = $coef->{y_min};
    my $y_max = $coef->{y_max};

    # vol proxy calculation
    my $vol_proxy;
    if (@$ticks and @$ticks == 20 and abs($date_pricing->epoch - $ticks->[0]->{epoch}) < 300) {
        my $sum = sum(map { log($ticks->[$_]->{quote} / $ticks->[$_ - 1]->{quote})**2 } (1 .. 19));
        $vol_proxy = sqrt($sum / 19);
    } else {
        $vol_proxy = 0.20;                                                 # 20% volatility
        $err       = 'Do not have enough ticks to calculate volatility';
    }
    $debug_information{base_vol_proxy} = $vol_proxy;

    # trend proxy calculation
    my $trend_proxy = 0;
    if (not $err) {
        my $ma_step = 7;
        my $avg     = sum(map { $_->{quote} } @$ticks[-$ma_step .. -1]) / $ma_step;
        my $x       = ($ticks->[-1]{quote} - $avg) / $ticks->[-1]{quote};
        $trend_proxy = $x / $vol_proxy;
    }
    $debug_information{base_trend_proxy} = $trend_proxy;

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
    my $risk_markup = 0;
    # we assume if you have one tie coefficent, you have all ties.
    if ($coef and $coef->{tie_A}) {
        $risk_markup =
            min(-0.1, ($coef->{tie_A} * $trend_proxy**2 + $coef->{tie_B} + $coef->{tie_C} * $vol_proxy + $coef->{tie_D} * sqrt($vol_proxy)) / 2);
        my $ten_minutes_int = Time::Duration::Concise->new(interval => '10m');
        # do not discount if the contract is affected by economic events.
        my $tie_factor = $affected_by_economic_events ? 0 : 0.75;
        $risk_markup .= $tie_factor;

        if (   ($debug_information{base_trend_proxy} > $x_max)
            or ($debug_information{base_trend_proxy} < $x_min)
            or ($debug_information{base_vol_proxy} > $y_max)
            or ($debug_information{base_vol_proxy} < $y_min))
        {
            $risk_markup += 0.03;
        }
        $debug_information{risk_markup} = $risk_markup;
    } else {
        $err = "Missing coefficients";
    }

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

1;
