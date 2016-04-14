package BOM::MarketData::VolSurface::Empirical;

use Moose;

use Machine::Epsilon;
use Math::Gauss qw(pdf);
use Cache::RedisDB;
use List::Util qw(max min sum);
use List::MoreUtils qw(uniq);
use Tie::Scalar::Timeout;
use Time::Duration::Concise;
use YAML::XS qw(LoadFile);

use Quant::Framework::EconomicEventCalendar;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Market::AggTicks;
use BOM::Market::Underlying;
use BOM::Market::Types;

my $news_categories = LoadFile('/home/git/regentmarkets/bom-market/config/files/economic_events_categories.yml');
my $coefficients    = LoadFile('/home/git/regentmarkets/bom-market/config/files/volatility_calibration_coefficients.yml');

sub get_volatility {
    my ($self, $args) = @_;

    # naked volatility
    my $underlying = $self->underlying;
    my ($current_epoch, $seconds_to_expiration, $economic_events) =
        @{$args}{'current_epoch', 'seconds_to_expiration', 'economic_events'};

    $self->error('current_epoch is not provided to get_volatility') unless $current_epoch;

    unless ($seconds_to_expiration) {
        $self->error('seconds_to_expiration is not provided to get_volatility');
        $seconds_to_expiration = 0;    #hard-coded it to zero second
    }

    # for contract where volatility doesn't matter,
    # we will return the long term vol.
    if ($args->{uses_flat_vol}) {
        return $self->long_term_vol;
    }

    my $lookback_interval = Time::Duration::Concise->new(interval => max(900, $seconds_to_expiration) . 's');
    my $fill_cache = $args->{fill_cache} // 1;

    my $at    = BOM::Market::AggTicks->new;
    my $ticks = $at->retrieve({
        underlying   => $underlying,
        interval     => $lookback_interval,
        ending_epoch => $current_epoch,
        fill_cache   => $fill_cache,
    });

    my $returns_sep = 4;
    $self->error('Insufficient tick interval to get_volatility') if @$ticks <= $returns_sep;

    my ($tick_count, $real_periods) = (0, 0);
    my @tick_epochs = uniq map { $_->{epoch} } @$ticks;
    my (@time_samples_past, @returns_squared);
    for (my $i = $returns_sep; $i <= $#tick_epochs; $i++) {
        push @time_samples_past, ($tick_epochs[$i] + $tick_epochs[$i - $returns_sep]) / 2;
        my $dt = $tick_epochs[$i] - $tick_epochs[$i - $returns_sep];
        push @returns_squared, ((log($ticks->[$i]->{quote} / $ticks->[$i - 4]->{quote})**2) * 252 * 86400 / $dt);
        $real_periods++;
        $tick_count += $ticks->[$i]->{count};
    }

    my $average_tick_count = ($tick_count) ? ($tick_count / $real_periods) : 0;
    $self->average_tick_count($average_tick_count);
    # check to make sure that 80% of the interval in the lookback period has ticks.
    my $interval_threshold = int(($lookback_interval->minutes * $returns_sep + 1) * 0.8);
    $self->error('Insufficient ticks in each interval to get_volatility') if ($real_periods + $returns_sep < $interval_threshold);

    # if there's error we just return long term volatility
    return $self->long_term_vol if $self->error;

    my $categorized_events = $self->_categorized_economic_events($economic_events);
    my $weights            = _calculate_weights(\@time_samples_past, $categorized_events);
    my $sum_vol            = sum map { $returns_squared[$_] * $weights->[$_] } (0 .. $#time_samples_past);
    my $observed_vol       = sqrt($sum_vol / sum(@$weights));

    my $c_start = $args->{current_epoch};
    my $c_end   = $c_start + $args->{seconds_to_expiration};
    my @time_samples_fut;
    for (my $i = $c_start; $i <= $c_end; $i += 15) {
        push @time_samples_fut, $i;
    }

    #seasonality curves
    my $seasonality_past = $self->_get_volatility_seasonality_areas(\@time_samples_past);
    my $seasonality_fut  = $self->_get_volatility_seasonality_areas(\@time_samples_fut);

    #news triangles
    #no news if not requested
    my $news_past = [(1) x (scalar @time_samples_past)];
    my $news_fut  = [(1) x (scalar @time_samples_fut)];
    if ($args->{include_news_impact}) {
        my $contract_details = {
            start    => $c_start,
            duration => $args->{seconds_to_expiration},
        };
        $news_past = _calculate_news_triangle(\@time_samples_past, $categorized_events, $contract_details);
        $news_fut  = _calculate_news_triangle(\@time_samples_fut,  $categorized_events, $contract_details);
    }

    my $past_sum           = sum(map { ($seasonality_past->[$_] * $news_past->[$_])**2 * $weights->[$_] } (0 .. $#time_samples_past));
    my $past_seasonality   = sqrt($past_sum / sum(@$weights));
    my $future_sum         = sum(map { ($seasonality_fut->[$_] * $news_fut->[$_])**2 } (0 .. $#time_samples_fut));
    my $future_seasonality = sqrt($future_sum / scalar(@time_samples_fut));

    return $self->_seasonalize({
        volatility => $observed_vol,
        past       => $past_seasonality,
        future     => $future_seasonality,
        %$args
    });
}

sub _seasonalize {
    my ($self, $args) = @_;

    my ($past, $future) = @{$args}{'past', 'future'};

    my $ltp_volatility_seasonality = $future;
    my $stp_volatility_seasonality = $future / $past;
    $stp_volatility_seasonality = min(2, max($stp_volatility_seasonality, 0.5));

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

sub _categorized_economic_events {
    my ($self, $raw_events) = @_;

    my $underlying = $self->underlying;
    my @events;
    foreach my $event (@$raw_events) {
        my $event_name = $event->{event_name};
        $event_name =~ s/\s/_/g;
        my $key             = $underlying->symbol . '_' . $event->{symbol} . '_' . $event->{impact} . '_' . $event_name;
        my $default         = $underlying->symbol . '_' . $event->{symbol} . '_' . $event->{impact} . '_default';
        my $news_parameters = $news_categories->{$key} // $news_categories->{$default};

        next unless $news_parameters;
        $news_parameters->{release_time} = Date::Utility->new($event->{release_date})->epoch;
        push @events, $news_parameters;
    }

    return \@events;
}

sub _calculate_weights {
    my ($times, $news_array) = @_;

    my @times    = @$times;
    my @combined = (1) x scalar(@times);
    foreach my $news (@$news_array) {
        my @weights;
        foreach my $time (@$times) {
            my $width = $time < $news->{release_time} ? 2 * 60 : 2 * 60 + $news->{duration};
            push @weights, 1 / (1 + pdf($time, $news->{release_time}, $width) / pdf(0, 0, $width) * ($news->{magnitude} - 1));
        }
        @combined = map { min($weights[$_], $combined[$_]) } (0 .. $#times);
    }

    return \@combined;
}

sub _calculate_news_triangle {
    my ($times, $news_array, $contract) = @_;

    my @times    = @$times;
    my @combined = (1) x scalar(@times);
    foreach my $news (@$news_array) {
        my $effective_news_time = _get_effective_news_time($news->{release_time}, $contract->{start}, $contract->{duration});
        # +1e-9 is added to prevent a division by zero error if news magnitude is 1
        my $eps = machine_epsilon();
        my $decay_coef = -log(2 / ($news->{magnitude} - 1 + $eps)) / $news->{duration};
        my @triangle;
        foreach my $time (@$times) {
            if ($time < $effective_news_time) {
                push @triangle, 1;
            } else {
                my $chunk = ($news->{magnitude} - 1) * exp(-$decay_coef * ($time - $effective_news_time)) + 1;
                push @triangle, $chunk;
            }
        }
        @combined = map { max($triangle[$_], $combined[$_]) } (0 .. $#times);
    }

    return \@combined;
}

sub _get_effective_news_time {
    my ($news_time, $contract_start, $contract_duration) = @_;

    my $five_minutes_in_seconds = 5 * 60;
    my $shift_seconds           = 0;
    my $contract_end            = $contract_start + $contract_duration;
    if ($news_time > $contract_start - $five_minutes_in_seconds and $news_time < $contract_start) {
        $shift_seconds = $contract_start - $news_time;
    } elsif ($news_time < $contract_end + $five_minutes_in_seconds and $news_time > $contract_end - $five_minutes_in_seconds) {
        # Always shifts to the contract start time if duration is less than 5 minutes.
        my $max_shift = min($five_minutes_in_seconds, $contract_duration);
        my $desired_start = $contract_end - $max_shift;
        $shift_seconds = $desired_start - $news_time;
    }

    my $effective_time = $news_time + $shift_seconds;

    return $effective_time;
}

sub _get_volatility_seasonality_areas {
    my ($self, $times) = @_;

    my @seasonality;
    my $secondly_seasonality = $self->per_second_seasonality_curve;
    foreach my $time (@$times) {
        my $second_of_day = $time % 86400;
        push @seasonality, $secondly_seasonality->[$second_of_day];
    }

    return \@seasonality;
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
    my $coef = $coefficients->{$which};
    return $underlying->submarket->name eq 'minor_pairs' ? $coef->{frxUSDJPY} : $coef->{$underlying->symbol};
}

has [qw(long_term_prediction average_tick_count error)] => (
    is      => 'rw',
    default => undef,
);

no Moose;
__PACKAGE__->meta->make_immutable;
1;
