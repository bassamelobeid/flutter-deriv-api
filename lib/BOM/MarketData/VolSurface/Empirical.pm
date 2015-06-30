package BOM::MarketData::VolSurface::Empirical;

use Moose;

use Cache::RedisDB;
use List::Util qw(max min sum);
use List::MoreUtils qw(uniq);
use Tie::Scalar::Timeout;
use POSIX qw(ceil);
use Time::Duration::Concise::Localize;

use BOM::MarketData::Fetcher::VolSurface;
use BOM::Market::AggTicks;
use BOM::Market::Types;

sub get_volatility {
    my ($self, $args) = @_;

    my ($naked_vol, $average_tick_count, $err) = @{$self->_naked_vol($args)}{'naked_vol', 'average_tick_count', 'err'};

    return {
        volatility         => $naked_vol,
        average_tick_count => $average_tick_count,
        err                => $err,
    };
}

sub get_seasonalized_volatility {
    my ($self, $args) = @_;

    my ($naked_vol, $average_tick_count, $err) = @{$self->_naked_vol($args)}{'naked_vol', 'average_tick_count', 'err'};
    my ($past, $fut) = $self->_get_volatility_seasonality_areas($args);
    my $past_vol_seasonality   = sum(map { $_**2 } @$past);
    my $future_vol_seasonality = sum(map { $_**2 } @$fut);
    my $seasonalized_vol       = $self->_seasonalize({
        volatility => $naked_vol,
        past       => $past_vol_seasonality,
        future     => $future_vol_seasonality,
        steps      => scalar @$fut,
        %$args
    });
    return {
        volatility           => $seasonalized_vol,
        average_tick_count   => $average_tick_count,
        long_term_prediction => $self->long_term_prediction,
        err                  => $err,
    };
}

sub get_seasonalized_volatility_with_news {
    my ($self, $args) = @_;

    my ($naked_vol, $average_tick_count, $err) = @{$self->_naked_vol($args)}{'naked_vol', 'average_tick_count', 'err'};
    my ($vs_past,                    $vs_fut)                       = $self->_get_volatility_seasonality_areas($args);
    my ($eco_past,                   $eco_fut)                      = $self->_get_economic_event_seasonality_areas($args);
    my ($past_seasonality_with_news, $future_seasonality_with_news) = (0, 0);
    my $steps = scalar @$vs_fut - 1;
    for my $n (0 .. $steps) {
        $past_seasonality_with_news   += ($vs_past->[$n] * ($eco_past->[$n] // 1))**2;
        $future_seasonality_with_news += ($vs_fut->[$n] *  ($eco_fut->[$n]  // 1))**2;
    }
    my $seasonalized_vol = $self->_seasonalize({
        volatility => $naked_vol,
        past       => $past_seasonality_with_news,
        future     => $future_seasonality_with_news,
        steps      => $steps,
        %$args
    });
    return {
        volatility           => $seasonalized_vol,
        average_tick_count   => $average_tick_count,
        long_term_prediction => $self->long_term_prediction,
        err                  => $err,
    };
}

sub _naked_vol {
    my ($self, $args) = @_;

    my $underlying = $self->underlying;
    my ($current_epoch, $seconds_to_expiration) =
        @{$args}{'current_epoch', 'seconds_to_expiration'};

    my $cache_key = $underlying->symbol . '-' . $current_epoch . '-' . $seconds_to_expiration;
    # if parameters to get volatility match, it is the same vol.
    if (my $cache_vol = $self->_naked_vol_cache->{$cache_key}) {
        $cache_vol->{cache} = 1;
        return $cache_vol;
    }

    my $lookback_interval = Time::Duration::Concise::Localize->new(interval => max(900, $seconds_to_expiration) . 's');
    my $fill_cache = $args->{fill_cache} // 1;

    my $real_periods = 0;
    my $at           = BOM::Market::AggTicks->new;
    my $ticks        = $at->retrieve({
        underlying   => $underlying,
        interval     => $lookback_interval,
        ending_epoch => $current_epoch,
        fill_cache   => $fill_cache,
    });

    my ($total_ticks, $sum_squaredinput, $variance) = (0) x 3;
    my $length      = scalar @$ticks;
    my $returns_sep = $at->returns_to_agg_ratio;
    if ($length > $returns_sep) {
        # Can compute vol.
        for (my $i = $returns_sep; $i < $length; $i++) {
            $real_periods++;
            my $return = log($ticks->[$i]{value} / $ticks->[$i - $returns_sep]{value});
            $sum_squaredinput += ($return**2);
            $total_ticks += $ticks->[$i]{full_count};
        }
        $variance = $at->annualization / ($length - $returns_sep) * $sum_squaredinput;
    }

    my $uc_vol = sqrt($variance) || $self->long_term_vol;    # set vol to long term vol if variance goes to zero.

    my $average_tick_count = ($real_periods > 0) ? $total_ticks / $real_periods : 0;
    my $err;
    $err = 1 if ($real_periods + 1 < int($lookback_interval->minutes) * 0.8);

    my $ref = {
        naked_vol          => $uc_vol,
        average_tick_count => $average_tick_count,
        err                => $err,
    };
    $self->_naked_vol_cache->{$cache_key} = $ref;

    return $ref;
}

sub _seasonalize {
    my ($self, $args) = @_;

    my ($past, $future) = @{$args}{'past', 'future'};
    my $steps = $args->{steps};

    my $ltp_volatility_seasonality = sqrt($future / $steps);
    my $stp_volatility_seasonality = sqrt($future / $past);
    $stp_volatility_seasonality = min(1.6, max($stp_volatility_seasonality, 0.5));

    my $duration_coef        = $self->_get_coefficients('duration_coef');
    my $minutes_to_expiry    = $args->{seconds_to_expiration} / 60;
    my $duration_factor      = exp(log($minutes_to_expiry) * $duration_coef->{data}->{slope} + $duration_coef->{data}->{intercept});
    my $long_term_prediction = $self->long_term_vol * $ltp_volatility_seasonality * $duration_factor;
    # hate to have to do this!
    $self->long_term_prediction($long_term_prediction);
    my $short_term_prediction = $args->{volatility} * $stp_volatility_seasonality;

    my $volatility_coef  = $self->_get_coefficients('volatility_coef');
    my $adjusted_ltp     = $long_term_prediction * $volatility_coef->{data}->{long_term};
    my $adjusted_stp     = $short_term_prediction * $volatility_coef->{data}->{short_term};
    my $seasonalized_vol = $adjusted_ltp + $adjusted_stp;

    my $min = 0.5 * $long_term_prediction;
    my $max = 2 * $long_term_prediction;
    $seasonalized_vol = min($max, max($min, $seasonalized_vol));

    return $seasonalized_vol;
}

sub _get_applicable_economic_events {
    my ($self, $start, $end) = @_;

    my $underlying = $self->underlying;

    my $news = BOM::MarketData::Fetcher::EconomicEvent->new->get_latest_events_for_period({
            from => Date::Utility->new($start),
            to   => Date::Utility->new($end)});
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

sub _get_economic_event_seasonality_areas {
    my ($self, $args) = @_;

    my $secs_to_expiry             = $args->{seconds_to_expiration};
    my $applicable_event_starttime = $args->{current_epoch} - $secs_to_expiry;
    my $applicable_event_endtime   = $args->{current_epoch} + $secs_to_expiry;

    my $secs_to_backout = $secs_to_expiry + 3600;
    my $effective_start = $args->{current_epoch};
    my $start           = $effective_start - $secs_to_backout;
    my $end             = $effective_start + $secs_to_expiry;
    my @economic_events = $self->_get_applicable_economic_events($start, $end);

    my (@sum_past_triangle, @sum_future_triangle);
    my $step_size  = $self->_step_size_for_duration($secs_to_expiry);
    my $step_count = ceil($secs_to_expiry / $step_size);

    foreach my $event (@economic_events) {
        my $end_of_effect = $event->release_date->plus_time_interval('1h');
        my $scale = $event->get_scaling_factor($self->underlying, 'vol');
        next if not defined $scale;
        my $x1             = $event->release_date->epoch;
        my $x2             = $end_of_effect->epoch;
        my $y1             = $scale;
        my $y2             = 1;
        my $triangle_slope = ($y1 - $y2) / ($x1 - $x2);
        my $intercept      = $y1 - $triangle_slope * $x1;

        my $n = 0;
        for (my $t = $applicable_event_starttime; $t <= $effective_start; $t += $step_size) {
            my $height = ($t > $x1 and $t <= $x2) ? $triangle_slope * $t + $intercept : 1;
            $sum_past_triangle[$n] = max($height, $sum_past_triangle[$n] // 1);
            $n++;
        }

        my $thirty_minutes_in_epoch = $event->release_date->plus_time_interval('30m')->epoch;
        my $primary_sum             = 5 * (sqrt((6 * (7 * $scale**2 + 4 * $scale + 1)) / $step_size));
        my $primary_sum_index       = 0;

        $n = 0;
        for (my $t = $effective_start; $t <= $end_of_effect; $t += $step_size) {
            $primary_sum_index++ if $t <= $x1;
            my $height = ($t > $thirty_minutes_in_epoch and $t <= $x2) ? $triangle_slope * $t + $intercept : 1;
            $sum_future_triangle[$n] = max($height, $sum_future_triangle[$n] // 1);
            $n++;
        }

        if (    $args->{current_epoch} <= $thirty_minutes_in_epoch
            and $applicable_event_endtime >= $event->release_date->epoch - 600)
        {
            $primary_sum_index = min($primary_sum_index, $secs_to_expiry);
            $sum_future_triangle[$primary_sum_index] = max($primary_sum, $sum_future_triangle[$primary_sum_index] // 1);
        }

        push @{$self->_cached_economic_events_info}, $event;
    }

    @sum_past_triangle   = @sum_past_triangle[-$step_count .. -1];        # Align with volatility slice.
    @sum_future_triangle = @sum_future_triangle[0 .. $step_count - 1];    # Align with volatility slice.

    return (\@sum_past_triangle, \@sum_future_triangle);
}

sub _get_volatility_seasonality_areas {
    my ($self, $args) = @_;

    my $second_of_day = $args->{current_epoch} % 86400;
    my $duration_seconds = max(0, $args->{seconds_to_expiration});

    my $secondly_seasonality = $self->per_second_seasonality_curve;
    my $step_size            = $self->_step_size_for_duration($duration_seconds);
    my (@future_seasonality, @past_seasonality);
    for (my $t = $second_of_day - $duration_seconds; $t <= $second_of_day + $duration_seconds; $t += $step_size) {
        my $area = $secondly_seasonality->[$t % 86400];
        push @future_seasonality, $area if ($t >= $second_of_day);
        push @past_seasonality,   $area if ($t <= $second_of_day);
    }

    return (\@past_seasonality, \@future_seasonality);
}

# This is only the approximate number of steps
# it will vary based on relative primality:
# 60 chosen for many small factors and clock-likeness
has approx_steps => (
    is      => 'ro',
    default => 60,
);

sub _step_size_for_duration {
    my ($self, $duration_seconds) = @_;

    return max(1, int($duration_seconds / $self->approx_steps));
}

has per_second_seasonality_curve => (
    is         => 'ro',
    lazy_build => 1,
);

# Cache curves in process, pull from Redis when necessary.
tie my $curve_cache, 'Tie::Scalar::Timeout', EXPIRES => '+1h';

sub _build_per_second_seasonality_curve {
    my $self = shift;

    my $symbol = $self->underlying->symbol;
    $curve_cache //= {};    # Expiration leads to undef.

    my $per_second = $curve_cache->{$symbol};
    if (not $per_second) {
        my $key_space = 'SECONDLY_SEASONALITY';
        $per_second = Cache::RedisDB->get($key_space, $symbol);

        if (not $per_second) {
            my $coefficients = $self->_get_coefficients('volatility_seasonality_coef')->{data}
                || confess 'No volatility seasonality coefficients for this underlying [' . $symbol . ']';
            my $interpolator = Math::Function::Interpolator->new(points => $coefficients);
            # The coefficients from the YAML are stored as hours. We want to do per-second.
            $per_second = [map { $interpolator->cubic($_ / 3600) } (0 .. 86399)];
            Cache::RedisDB->set($key_space, $symbol, $per_second, 43201);    # Recompute every 12 hours or so
        }
        $curve_cache->{$symbol} = $per_second;
    }

    return $per_second;
}

has underlying => (
    is       => 'ro',
    isa      => 'bom_underlying_object',
    coerce   => 1,
    required => 1,
);

has _coefficients => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build__coefficients {
    my $self = shift;

    return YAML::CacheLoader::LoadFile('/home/git/regentmarkets/bom/config/files/volatility_calibration_coefficients.yml');
}

has long_term_vol => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_long_term_vol {
    my $self = shift;
    my $volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $self->underlying});
    return $volsurface->get_volatility({
        days              => 7,
        $volsurface->type => $volsurface->atm_spread_point
    });
}

sub _get_coefficients {
    my ($self, $which, $underlying) = @_;
    $underlying = $self->underlying if not $underlying;
    my $coef = $self->_coefficients->{$which};
    return $underlying->submarket->name eq 'minor_pairs' ? $coef->{frxUSDJPY} : $coef->{$underlying->symbol};
}

has _naked_vol_cache => (
    is      => 'ro',
    default => sub { {} },
);

# This is never used.
has _cached_economic_events_info => (
    is      => 'ro',
    isa     => 'ArrayRef',
    default => sub { [] },
);

has long_term_prediction => (
    is      => 'rw',
    default => undef,
);

no Moose;
__PACKAGE__->meta->make_immutable;
1;
