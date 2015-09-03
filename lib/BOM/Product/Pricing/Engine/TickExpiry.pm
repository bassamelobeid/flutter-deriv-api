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

use BOM::Market::AggTicks;
use BOM::Market::Underlying;
use BOM::MarketData::Fetcher::EconomicEvent;

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
    my @required = qw(underlying_symbol pricing_date contract_type);
    if (grep { not $args->{$_} } @required) {
        $err = 'Insufficient input to calculate probability';
    }

    my %allowed_contract_type = (
        CALL => 1,
        PUT  => 1,
    );
    if (not $allowed_contract_type{$args->{contract_type}}) {
        $err = "Could not calculate probability for $args->{contract_type}";
    }

    my (%debug_information, $latest);
    my $coef  = LoadFile('/home/git/regentmarkets/bom/config/files/tick_trade_coefficients.yml')->{$args->{underlying_symbol}};
    my $start = Date::Utility->new($args->{pricing_date});
    ($latest, $err) = _get_ticks($args->{underlying_symbol}, $start);

    my ($vol_proxy, $trend_proxy);
    if (not $err) {
        my @latest = @$latest;
        # calculates vol proxy
        my $sum = sum(map { log($latest[$_]{quote} / $latest[$_ - 1]{quote})**2 } (1 .. 19));
        $vol_proxy = sqrt($sum / 19);
        $debug_information{vol_proxy} = $vol_proxy;
        # calculates trend proxy
        my $ma_step = $coef->{ma_step};
        my $avg     = sum(map { $_->{quote} } @$latest[-$ma_step .. -1]) / $ma_step;
        my $x       = ($latest[-1]{quote} - $avg) / $latest[-1]{quote};
        $trend_proxy = $x / $vol_proxy;
        $debug_information{trend_proxy} = $trend_proxy;
    } else {
        $vol_proxy   = 0.2;    # hardcoded 20%
        $trend_proxy = 0;      # no trend
    }

    my $x_min = $coef->{x_prime_min};
    my $x_max = $coef->{x_prime_max};
    my $y_min = $coef->{y_min};
    my $y_max = $coef->{y_max};

    $vol_proxy   = min($y_max, max($y_min, $vol_proxy));
    $trend_proxy = min($x_max, max($x_min, $trend_proxy));

    # calculates trend adjustment
    # A,B,C,D are paramters that defines the pricing "surface".  The values are obtained emperically.
    my $f1               = $coef->{A} * sqrt($vol_proxy) + $coef->{B} * $vol_proxy + $coef->{C};
    my $f2               = 1 + exp($coef->{D} * $trend_proxy);
    my $trend_adjustment = $f1 * (1 / $f2 - 0.5);
    $debug_information{trend_adjustment} = $trend_adjustment;

    # probability
    my $base_probability = 0.5;
    my $probability = $args->{contract_type} eq 'PUT' ? $base_probability - $trend_adjustment : $base_probability + $trend_adjustment;
    $probability = min(1, max(0.5, $probability));

    # risk_markup
    my $risk_markup = 0;
    my $y           = $vol_proxy;
    my $x           = $trend_proxy;
    # we assume if you have one tie coefficent, you have all ties.
    if ($coef and $coef->{tie_A}) {
        $risk_markup = min(-0.1, ($coef->{tie_A} * $x**2 + $coef->{tie_B} + $coef->{tie_C} * $y + $coef->{tie_D} * sqrt($y)) / 2);
        my $ten_minutes_int = Time::Duration::Concise->new(interval => '10m');
        my $start_period    = $start->minus_time_interval($ten_minutes_int);
        my $end_period      = $start->plus_time_interval($ten_minutes_int);
        my @economic_events = _get_applicable_economic_events($args->{underlying_symbol}, $start_period, $end_period);
        my $tie_factor      = (@economic_events) ? 0 : 0.75;
        $risk_markup .= $tie_factor;

        if (   ($debug_information{trend_proxy} > $x_max)
            or ($debug_information{trend_proxy} < $x_min)
            or ($debug_information{vol_proxy} > $y_max)
            or ($debug_information{vol_proxy} < $y_min))
        {
            $risk_markup += 0.03;
        }
        $debug_information{risk_markup} = $risk_markup;
    } else {
        $err = "Missing coefficients for $args->{underlying_symbol}";
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

sub _get_applicable_economic_events {
    my ($underlying_symbol, $start, $end) = @_;

    my $underlying = BOM::Market::Underlying->new($underlying_symbol);
    my $news       = BOM::MarketData::Fetcher::EconomicEvent->new->get_latest_events_for_period({
        from => $start,
        to   => $end
    });
    my @influential_currencies = ('USD', 'AUD', 'CAD', 'CNY', 'NZD');
    my @applicable_symbols = uniq($underlying->quoted_currency_symbol, $underlying->asset_symbol, @influential_currencies);
    my @applicable_news;

    foreach my $symbol (@applicable_symbols) {
        my @news = grep { $_->symbol eq $symbol } @$news;
        push @applicable_news, @news;
    }
    @applicable_news =
        sort { $a->release_date->epoch <=> $b->release_date->epoch } @applicable_news;

    return @applicable_news;
}

sub _get_ticks {
    my ($underlying_symbol, $start) = @_;

    my @ticks;
    # if requested time is more than 5 minutes from now.
    # this could happen in backtest and bpot.
    if (time - $start->epoch > 300) {
        my $ticks = BOM::Market::Underlying->new($underlying_symbol)->ticks_in_between_end_limit({
            end_time => $start->epoch,
            limit    => 20,
        });
        my @sorted = map { {quote => $_->quote, epoch => $_->epoch} } sort { $a->epoch <=> $b->epoch } @$ticks;
    } else {
        @ticks = map { Load($_) } @{Cache::RedisDB->redis->lrange("LATEST_TICKS::" . $underlying_symbol, -20, -1)};
    }

    my $err;
    # if latest tick is more than 5 minutes old, flag!
    if (@ticks and @ticks == 20 and abs($start->epoch - $ticks[0]{epoch}) > 300) {
        $err = 'Do not have latest ticks to calculate volatility';
    }

    return (\@ticks, $err);
}

1;
