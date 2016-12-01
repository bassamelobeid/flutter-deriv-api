package BOM::MarketData::VolSurface::Empirical;

use Moose;

use Machine::Epsilon;
use Math::Gauss::XS qw(pdf);
use Cache::RedisDB;
use List::Util qw(max min sum);
use List::MoreUtils qw(uniq);
use Tie::Scalar::Timeout;
use Time::Duration::Concise;
use YAML::XS qw(LoadFile);

use Quant::Framework::EconomicEventCalendar;

use BOM::MarketData::Fetcher::VolSurface;
use BOM::MarketData::Types;

use BOM::System::RedisReplicated;
use Data::Resample::ResampleCache;
use Data::Resample::TicksCache;

my $news_categories = LoadFile('/home/git/regentmarkets/bom-market/config/files/economic_events_categories.yml');
my $coefficients    = LoadFile('/home/git/regentmarkets/bom-market/config/files/volatility_calibration_coefficients.yml');
my $returns_sep     = 4;

sub get_volatility {
    my ($self, $args) = @_;

    # for contract where volatility doesn't matter,
    # we will return the long term vol.
    if ($args->{uses_flat_vol}) {
        return $self->long_term_vol;
    }

    # naked volatility
    my $underlying      = $self->underlying;
    my $economic_events = $args->{economic_events};

    unless ($args->{current_epoch} and $args->{seconds_to_expiration}) {
        $self->error('Non zero arguments of \'current_epoch\' and \'seconds_to_expiration\' are required to get_volatility.');
        return $self->long_term_vol;
    }

    my $interval = Time::Duration::Concise->new(interval => max(900, $args->{seconds_to_expiration}) . 's');
    my $fill_cache = $args->{fill_cache} // 1;

    my $resample_cache = Data::Resample::ResampleCache->new({
        redis_read  => BOM::System::RedisReplicated::redis_read(),
        redis_write => BOM::System::RedisReplicated::redis_write(),
    });
#    my $ticks_cache = Data::Resample::TicksCache->new({
#        redis => Cache::RedisDB->redis,
#    });

    my $ticks;
    if ($underlying->for_date) {
        my $raw_ticks = $underlying->ticks_in_between_start_end({
            start_time => $args->{current_epoch} - $interval->seconds,
            end_time   => $args->{current_epoch},
        });

        my @rev_ticks = reverse @$raw_ticks;
        $ticks = $resample_cache->resample_cache_backfill({
            symbol => $underlying->symbol,
            ticks  => \@rev_ticks,
        });
    } else {

        $ticks = $resample_cache->resample_cache_get({
            symbol      => $underlying->symbol,
            start_epoch => $args->{current_epoch} - $interval->seconds,
            end_epoch   => $args->{current_epoch},
        });

    }

#    my $latest_tick = $ticks_cache->tick_cache_get_num_ticks({
#        symbol    => $underlying->symbol,
#        end_epoch => $args->{current_epoch},
#        num       => 1,
#    });
#    push @$ticks, $latest_tick->[0] if (scalar(@$latest_tick) and scalar(@$ticks) and $latest_tick->[0]->{epoch} > $ticks->[-1]->{agg_epoch});

    # minimum of 1 second to avoid division by zero error.
    my $requested_interval = Time::Duration::Concise->new(interval => max(1, $args->{seconds_to_expiration}));
    # $actual_lookback_interval used to be the contract duration, but we have changed the concept.
    # We will use the any amount of good ticks we get from the cache and scale the volatility by duration.
    # Corrupted of duplicated ticks will be discarded.

    my @good_ticks = $ticks->[-1];    # first tick is always good
    my $counter    = 0;
    for (my $i = -1; $i >= -$#$ticks; $i--) {
        if ($ticks->[$i]->{epoch} != $ticks->[$i - 1]->{epoch}) {
            unshift @good_ticks, $ticks->[$i - 1];
            $counter = 0;
            next;
        }
        $counter++;
        # if there's 10 stale intervals, we will discard the last added tick
        # and everything else after that.
        shift @good_ticks and last if ($counter == 10);
    }
    my $actual_lookback_interval =
        Time::Duration::Concise->new(
        interval => min($requested_interval->seconds, (@good_ticks < 2 ? 0 : $good_ticks[-1]->{epoch} - $good_ticks[0]->{epoch})));
    $self->volatility_scaling_factor($actual_lookback_interval->seconds / $requested_interval->seconds);

    my $categorized_events = $self->_categorized_economic_events($economic_events);

    my $c_start = $args->{current_epoch};
    my $c_end   = $c_start + $args->{seconds_to_expiration};
    my @time_samples_fut;

    for (my $i = $c_start; $i <= $c_end; $i += 15) {
        push @time_samples_fut, $i;
    }

    #seasonality future
    my $seasonality_fut = $self->_get_volatility_seasonality_areas(\@time_samples_fut);

    #news triangles future
    #no news if not requested
    my $news_fut = [(1) x (scalar @time_samples_fut)];
    if ($args->{include_news_impact}) {
        my $contract_details = {
            start    => $c_start,
            duration => $args->{seconds_to_expiration},
        };
        $news_fut = _calculate_news_triangle(\@time_samples_fut, $categorized_events, $contract_details);
    }

    my $future_sum                 = sum(map { ($seasonality_fut->[$_] * $news_fut->[$_])**2 } (0 .. $#time_samples_fut));
    my $future_seasonality         = sqrt($future_sum / scalar(@time_samples_fut));
    my $ltp_volatility_seasonality = $future_seasonality;
    my $duration_coef              = $self->_get_coefficients('duration_coef');
    my $minutes_to_expiry          = $args->{seconds_to_expiration} / 60;
    my $duration_factor            = exp(log($minutes_to_expiry) * $duration_coef->{data}->{slope} + $duration_coef->{data}->{intercept});
    my $long_term_prediction       = $self->long_term_vol * $ltp_volatility_seasonality * $duration_factor;
    # hate to have to do this but this is needed in intraday pricing engine!
    $self->long_term_prediction($long_term_prediction);

    my $short_term_prediction;
    if (@good_ticks < 5) {
        # we don't have enough ticks to do anything.
        $short_term_prediction = machine_epsilon();
    } else {
        my @tick_epochs = map { $_->{epoch} } @good_ticks;
        my @time_samples_past = map { ($tick_epochs[$_] + $tick_epochs[$_ - $returns_sep]) / 2 } ($returns_sep .. $#tick_epochs);
        my $weights = _calculate_weights(\@time_samples_past, $categorized_events);
        my $observed_vol     = _calculate_observed_volatility(\@good_ticks, \@time_samples_past, \@tick_epochs, $weights);
        my $seasonality_past = $self->_get_volatility_seasonality_areas(\@time_samples_past);
        my $news_past        = [(1) x (scalar @time_samples_past)];
        if ($args->{include_news_impact}) {
            my $contract_details = {
                start    => $c_start,
                duration => $args->{seconds_to_expiration},
            };
            $news_past = _calculate_news_triangle(\@time_samples_past, $categorized_events, $contract_details);
        }
        my $past_sum                   = sum(map { ($seasonality_past->[$_] * $news_past->[$_])**2 * $weights->[$_] } (0 .. $#time_samples_past));
        my $past_seasonality           = sqrt($past_sum / sum(@$weights));
        my $stp_volatility_seasonality = $future_seasonality / $past_seasonality;
        $stp_volatility_seasonality = min(2, max($stp_volatility_seasonality, 0.5));
        $short_term_prediction = $observed_vol * $stp_volatility_seasonality;
    }

    my $volatility_coef  = $self->_get_coefficients('volatility_coef');
    my $adjusted_ltp     = $long_term_prediction * (1 + $self->volatility_scaling_factor * ($volatility_coef->{data}->{long_term_weight} - 1));
    my $adjusted_stp     = $short_term_prediction * $volatility_coef->{data}->{short_term_weight} * $self->volatility_scaling_factor;
    my $seasonalized_vol = $adjusted_ltp + $adjusted_stp;

    my $min = 0.5 * $long_term_prediction;
    my $max = 2 * $long_term_prediction;
    $seasonalized_vol = min($max, max($min, $seasonalized_vol));

    return $seasonalized_vol;
}

sub _calculate_observed_volatility {
    my ($ticks, $time_samples_past, $tick_epochs, $weights) = @_;

    my @returns_squared;
    for (my $i = $returns_sep; $i <= $#$tick_epochs; $i++) {
        my $dt = $tick_epochs->[$i] - $tick_epochs->[$i - $returns_sep];
        push @returns_squared, ((log($ticks->[$i]->{quote} / $ticks->[$i - 4]->{quote})**2) * 252 * 86400 / $dt);
    }

    my $sum_vol = sum map { $returns_squared[$_] * $weights->[$_] } (0 .. $#$time_samples_past);
    my $observed_vol = sqrt($sum_vol / sum(@$weights));

    return $observed_vol;
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
        my %dereference     = $news_parameters ? %$news_parameters : ();

        next unless keys %dereference;
        $dereference{release_time} = Date::Utility->new($event->{release_date})->epoch;
        push @events, \%dereference;
    }

    return \@events;
}

sub _calculate_weights {
    my ($times, $news_array) = @_;

    my @times    = @$times;
    my @combined = (1) x scalar(@times);
    foreach my $news (@$news_array) {
        foreach my $idx (0 .. $#times) {
            my $time   = $times[$idx];
            my $width  = $time < $news->{release_time} ? 2 * 60 : 2 * 60 + $news->{duration};
            my $weight = 1 / (1 + pdf($time, $news->{release_time}, $width) / pdf(0, 0, $width) * ($news->{magnitude} - 1));
            $combined[$idx] = min($combined[$idx], $weight);
        }
    }

    return \@combined;
}

sub _calculate_news_triangle {
    my ($times, $news_array, $contract) = @_;

    my @times    = @$times;
    my @combined = (1) x scalar(@times);
    my $eps      = machine_epsilon();
    foreach my $news (@$news_array) {
        my $effective_news_time = _get_effective_news_time($news->{release_time}, $contract->{start}, $contract->{duration});
        # +1e-9 is added to prevent a division by zero error if news magnitude is 1
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
            my $coefficients = $self->_get_coefficients('volatility_seasonality_coef')->{data};
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
    isa      => 'underlying_object',
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
    my $recorded_date = $volsurface->recorded_date;
    return $volsurface->get_volatility({
        from              => $recorded_date,
        to                => $recorded_date->plus_time_interval('7d'),
        $volsurface->type => $volsurface->atm_spread_point
    });
}

sub _get_coefficients {
    my ($self, $which, $underlying) = @_;
    $underlying ||= $self->underlying;
    my $coef = $coefficients->{$which};

    die "Volatility calibration coefficients of $which is empty"
        unless ref $coef eq 'HASH';

    my $reference_symbol = $underlying->submarket->name eq 'minor_pairs' ? 'frxUSDJPY' : $underlying->symbol;
    my $result = $coef->{$reference_symbol};

    die "No $which coefficients for this underlying [$reference_symbol]"
        unless ref $result eq 'HASH';

    return $result;
}

has [qw(long_term_prediction error)] => (
    is      => 'rw',
    default => undef,
);

=head2 volatility_scaling_factor

To scale volatility due to uncertainty in volatility calculation algorithm.

On Monday mornings or the begining of the day where previous day is a non-trading day, there won't be ticks available over the weekends.

We could only depend on the long term prediction on our volatility model, hence we need to adjust for that uncertainty in price with a volatility spread markup in Intraday::Forex model.

=cut

has volatility_scaling_factor => (
    is      => 'rw',
    default => 1,
);

no Moose;
__PACKAGE__->meta->make_immutable;
1;
