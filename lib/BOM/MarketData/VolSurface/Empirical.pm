package BOM::MarketData::VolSurface::Empirical;

use Moose;

use Machine::Epsilon;
use Math::Gauss::XS qw(pdf);
use List::Util qw(max min sum);
use Time::Duration::Concise;
use YAML::XS qw(LoadFile);

use BOM::System::Chronicle;
use Volatility::Seasonality;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::MarketData::Types;
use BOM::Market::DataDecimate;

my $coefficients = LoadFile('/home/git/regentmarkets/bom-market/config/files/volatility_calibration_coefficients.yml');
my $returns_sep  = 4;

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
    my $backprice = ($self->underlying->for_date) ? 1 : 0;

    my $ticks = BOM::Market::DataDecimate->new()->decimate_cache_get({
        underlying  => $underlying,
        start_epoch => $args->{current_epoch} - $interval->seconds,
        end_epoch   => $args->{current_epoch},
        backprice   => $backprice,
    });

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

    my $qfs = Volatility::Seasonality->new(chronicle_reader => BOM::System::Chronicle::get_chronicle_reader($underlying->for_date));
    my $categorized_events = $qfs->categorize_events($underlying->symbol, $economic_events);

    # Future time samples is extended for 5 minutes at both ends. This is to accommodate for the uncertainty of economic event impact kick-in time.
    # This will only be applied on contract less than 5 hours because of the decaying effect of economic event's impact.
    my $shifted_events =
        ($args->{include_news_impact} and $args->{seconds_to_expiration} < 5 * 3600)
        ? _apply_shifting_logic($categorized_events, $args->{current_epoch}, $args->{seconds_to_expiration})
        : $categorized_events;

    my $c_start = $args->{current_epoch};
    my $c_end   = $c_start + $args->{seconds_to_expiration};
    my @time_samples_fut;

    for (my $i = $c_start; $i <= $c_end; $i += 15) {
        push @time_samples_fut, $i;
    }

    #seasonality future
    my $seasonality_fut = $qfs->get_volatility_seasonality({
        underlying_symbol => $underlying->symbol,
        time_series       => \@time_samples_fut
    });

    #news triangles future
    #no news if not requested
    my $news_fut = [(1) x (scalar @time_samples_fut)];
    if ($args->{include_news_impact}) {
        $news_fut = $qfs->get_economic_event_seasonality({
            underlying_symbol  => $underlying->symbol,
            categorized_events => $shifted_events,
            time_series        => \@time_samples_fut,
        });
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
        my @time_samples_past = map { int(($tick_epochs[$_] + $tick_epochs[$_ - $returns_sep]) / 2) } ($returns_sep .. $#tick_epochs);
        my $weights = _calculate_weights(\@time_samples_past, $categorized_events);
        my $observed_vol = _calculate_observed_volatility(\@good_ticks, \@time_samples_past, \@tick_epochs, $weights);
        my $seasonality_past = $qfs->get_volatility_seasonality({
            underlying_symbol => $underlying->symbol,
            time_series       => \@time_samples_past
        });
        my $news_past = [(1) x (scalar @time_samples_past)];
        if ($args->{include_news_impact}) {
            $news_past = $qfs->get_economic_event_seasonality({
                underlying_symbol  => $underlying->symbol,
                categorized_events => $shifted_events,
                time_series        => \@time_samples_past
            });
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

sub _apply_shifting_logic {
    my ($economic_events, $contract_start, $contract_duration) = @_;

    my $five_minutes_in_seconds = 5 * 60;
    my $shift_seconds           = 0;
    my $contract_end            = $contract_start + $contract_duration;

    my @shifted;
    foreach my $event (@$economic_events) {
        my $news_time = $event->{release_epoch};
        if ($news_time > $contract_start - $five_minutes_in_seconds and $news_time < $contract_start) {
            push @shifted, +{%$event, release_epoch => $contract_start};
        } elsif ($news_time < $contract_end + $five_minutes_in_seconds and $news_time > $contract_end - $five_minutes_in_seconds) {
            # Always shifts to the contract start time if duration is less than 5 minutes.
            my $max_shift = min($five_minutes_in_seconds, $contract_duration);
            push @shifted, +{%$event, release_epoch => $contract_end - $max_shift};
        } else {
            push @shifted, $event;
        }
    }

    return \@shifted;
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

sub _calculate_weights {
    my ($times, $news_array) = @_;

    my @times    = @$times;
    my @combined = (1) x scalar(@times);
    foreach my $news (@$news_array) {
        foreach my $idx (0 .. $#times) {
            my $time   = $times[$idx];
            my $width  = $time < $news->{release_epoch} ? 2 * 60 : 2 * 60 + $news->{duration};
            my $weight = 1 / (1 + pdf($time, $news->{release_epoch}, $width) / pdf(0, 0, $width) * ($news->{magnitude} - 1));
            $combined[$idx] = min($combined[$idx], $weight);
        }
    }

    return \@combined;
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
