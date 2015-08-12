package BOM::Market::AggTicks;

=head1 NAME

BOM::Market::AggTicks

=head1 SYNOPSYS

    use BOM::Market::AggTicks;

=head1 DESCRIPTION

A wrapper to let us use Redis SortedSets to get aggregated tick data.

=cut

use 5.010;
use Moose;
use Carp;

use List::Util qw(min);
use Sereal qw(encode_sereal decode_sereal looks_like_sereal);

use Cache::RedisDB;
use Date::Utility;
use Time::Duration::Concise;
use Sereal::Encoder;
use BOM::System::Types;

=head2 agg_interval

A Time::Duration::Concise representing the time between aggregations.

=cut

has agg_interval => (
    is      => 'ro',
    isa     => 'bom_time_interval',
    default => '15s',
    coerce  => 1,
);

=head2 returns_interval

A Time::Duration::Concise representing the time between return calculations.

=cut

has returns_interval => (
    is      => 'ro',
    isa     => 'bom_time_interval',
    default => '1m',
    coerce  => 1,
);

=head2 returns_to_agg_ratio

The integer ratio between the returns_interval and agg_interval.

Cannot be overridden.

=cut

has returns_to_agg_ratio => (
    is       => 'ro',
    isa      => 'Int',
    init_arg => undef,
    default  => sub {
        my $self = shift;
        return $self->returns_interval->seconds / $self->agg_interval->seconds;
    },
);

sub BUILD {
    my $self = shift;

    my ($min, $max) = (1, 20);

    croak 'Unrecoverable error: the ratio ['
        . $self->returns_to_agg_ratio
        . '] between the supplied returns_interval ['
        . $self->returns_interval->as_string
        . '] and agg_interval ['
        . $self->agg_interval->as_string
        . '] is not an integer between ['
        . $min
        . '] and ['
        . $max . '].'
        unless ($self->returns_to_agg_ratio >= $min
        && $self->returns_to_agg_ratio <= $max);

    return;
}

=head2  retention_interval

A Time::Duration::Concise representing the total time we wish to keep aggregated ticks, defaults to 24 hours.

=cut

has retention_interval => (
    is      => 'ro',
    isa     => 'bom_time_interval',
    default => '12h',
    coerce  => 1,
);

=head2 annualization

The annualization factor for these ticks, given the returns_interval

=cut

has 'annualization' => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

my $annual_seconds = 60 * 60 * 24 * 252;

sub _build_annualization {
    my $self = shift;

    return $annual_seconds / $self->returns_interval->seconds;
}

# We'll just piggy back off Cache::RedisDB's knowledge of Redis.
sub _redis {
    return Cache::RedisDB->redis;
}

=head2 add

Add aggregated tick data to the cache.

=cut

sub add {
    my ($self, $args) = @_;

    my $which = $args->{underlying};
    my $epoch = $args->{epoch};
    my $value = $args->{value};
    my $agg   = (exists $args->{aggregated}) ? $args->{aggregated} : 1;
    my $unagg = ($agg) ? '' : 'ua';

    if ($unagg) {
        $args->{high}       = $value;
        $args->{low}        = $value;
        $args->{full_count} = 1;
    }

    if ($agg and my $rem = $epoch % $self->agg_interval->seconds) {

        croak 'Unrecoverable error: supplied epoch ['
            . $epoch
            . '] does not fall on '
            . $self->agg_interval->as_string
            . ' boundary, off by '
            . $rem
            . ' seconds.';
    }

    delete $args->{underlying};
    delete $args->{aggregated};

    my $key = $self->_make_key($which, $unagg);
    my $redis = $self->_redis;

    # Someone else will have to clear out the unaggregated ticks.
    $self->_cull_key($key, $epoch) if not($unagg);

    return $redis->zadd($key, $epoch, Sereal::Encoder->new({protocol_version => 2})->encode($args));
}

sub _cull_key {
    my ($self, $key, $epoch) = @_;

    my $redis = $self->_redis;

    my $retval;

# To mitigate nasty situations with pricing old bets, let the cache build to 5x the supposed number of ticks we're keeping
# culling all of the old ones.  This can still cause problems if we do it in the midst of them adding them,
# but I don't have a better solution
    if ($redis->zcard($key) > 5 * $self->retention_interval->seconds / $self->agg_interval->seconds) {
        $retval = $redis->zremrangebyscore($key, 0, time - ($self->retention_interval->seconds + 1));
    }

    # Try to make sure we only have one entry for each interval
    if ($epoch) {
        $retval = $redis->zremrangebyscore($key, $epoch, $epoch);
    }

    return $retval;
}

=head2 retrieve

Return the aggregated tick data for an underlying over the last BOM:TimeInterval

=cut

sub retrieve {
    my ($self, $args) = @_;

    my $which      = $args->{underlying};
    my $ti         = $args->{interval} || $self->retention_interval;
    my $end        = $args->{ending_epoch} || time;
    my $fill_cache = $args->{fill_cache} // 1;
    my $chunks     = $args->{chunks} || 1;

    my $agg_seconds = $self->agg_interval->seconds;

    # Always move back from here to the most recent exepected key
    my $keypoch = $end - ($end % $agg_seconds);
    my $back = min($ti->seconds, $self->retention_interval->seconds);
    my $start = $keypoch - $back;

    # Outside of our retention_interval always assume the ticks are missing
    if ($fill_cache and $start < time - $self->retention_interval->seconds) {
        $self->fill_from_historical_feed({
                underlying   => $which,
                ending_epoch => $keypoch,
                interval     => Time::Duration::Concise->new(
                    interval => $back,
                ),
            });
    }

    return $self->_cached_between_epochs($which, $start, $end, '', $chunks);
}

=head2 unaggregated_periods

Returns a number representing the number of aggregation periods queued in
unaggregated ticks on the provided underlying.

Useful for monitoring system availability, values should tend to be between 0.0 and 1.0
and never vary above 2.0.

=cut

sub unaggregated_periods {
    my ($self, $which) = @_;

    my @ticks = @{$self->_cached_between_epochs($which, 0, time, 'ua')};

    my $ua_seconds =
        (scalar @ticks > 1) ? $ticks[-1]->{epoch} - $ticks[0]->{epoch} : 0;

    return $ua_seconds / $self->agg_interval->seconds;
}

sub _cached_between_epochs {
    my ($self, $which, $start, $end, $ua, $chunks) = @_;

    my $redis = $self->_redis;
    $chunks ||= 1;
    my $chunk_secs = int(($end - $start) / $chunks);    # We'll leave of any early stuff missed.
    my $ua_checked;
    my @ticks;
    my $period_end   = $end;
    my $period_start = $end - $chunk_secs;
    my $key          = $self->_make_key($which, $ua);

    while ($period_start >= $start) {
        my @period_ticks = map { decode_sereal($_) } @{$redis->zrangebyscore($key, $period_start, $period_end)};

        # We might need the last rolling minute, but not for UA ticks.
        if (not $ua and not $ua_checked) {
            $ua_checked = 1;
            my ($earliest_tick) =
                @{$redis->zrange($self->_make_key($which, 'ua'), 0, 0)};
            if (looks_like_sereal($earliest_tick)) {
                $earliest_tick = decode_sereal($earliest_tick);
                if ($earliest_tick && $end >= $earliest_tick->{epoch}) {
                    my @latest = @{$self->_cached_between_epochs($which, $start, $end, 'ua')};
                    if (@latest) {
                        push @period_ticks,
                            {
                            epoch      => $end,
                            value      => $latest[-1]{value},
                            full_count => scalar(@latest),
                            };
                    }
                }
            }
        }
        push @ticks, \@period_ticks;
        $period_end   = $period_start;
        $period_start = $period_end - $chunk_secs;
    }

    return ($chunks == 1) ? $ticks[0] : \@ticks;
}

=head2 aggregate_to_epoch

Aggregate current unaggregated ticks for the supied underlying to the epoch supplied

    $at->aggregate_to_epoch(underlying => $underlying, epoch => $epoch});

=cut

sub aggregate_to_epoch {
    my ($self, $args) = @_;

    my $underlying = $args->{underlying};
    my $end        = $args->{epoch};

    my @values = map { $_->{value} } @{$self->_cached_between_epochs($underlying, 0, $end, 'ua')};

    $self->_add_ticks_for_epoch({
        underlying => $underlying,
        epoch      => $end,
        ticks      => \@values
    });

    $self->_redis->zremrangebyscore($self->_make_key($underlying, 'ua'), 0, $end);

    return 1;
}

=head2 fill_from_historical_feed

Gather known ticks from the past

    $at->fill_from_historical_feed({underlying => $underlying, [ending_epoch => $epoch, interval => $interval]});

Intervals longer than the retention interval will be shortened to the retention interval

=cut

sub fill_from_historical_feed {
    my ($self, $args) = @_;

    my $underlying = $args->{underlying};
    my $end = $args->{ending_epoch} || time;
    my $ti =
          $args->{interval}
        ? $args->{interval}->seconds
        : $self->retention_interval->seconds;
    my $agg_interval = $self->agg_interval->seconds;

    my $final_agg = $end - $end % $agg_interval;
    my $start = $end - min($ti, $self->retention_interval->seconds);
    $start = $start - $start % $agg_interval;
    my $first_agg = $start - $agg_interval;

    my $tick_data = $underlying->ticks_in_between_start_end({
        start_time => $first_agg,
        end_time   => $final_agg,
    });

    my @ordered_tick_data = reverse @$tick_data;

    my $first_added;
    my $last_added;
    my @tick_cache;
    my $doing_time = $first_agg + $agg_interval;
    my $prev_time  = $first_agg;
    my $added      = 0;

    TICK:
    while (my $tick = shift @ordered_tick_data) {
        last TICK
            if ($doing_time > $final_agg);    # Past the end of our requested period.
        if ($tick->epoch <= $doing_time) {

            # This tick belongs to our aggregation..
            unshift @tick_cache, $tick->quote;
        } else {
            # We've found all the ticks for this period, so add them in.
            if (
                $self->_add_ticks_for_epoch({
                        underlying => $underlying,
                        epoch      => $doing_time,
                        ticks      => \@tick_cache,
                    }))
            {
                $added++;
                $first_added ||= $doing_time;
                $last_added = $doing_time;
            }

            $prev_time = $doing_time;
            $doing_time += $agg_interval;
            unshift @ordered_tick_data, $tick;
            @tick_cache = ();
        }
    }

    return ($added, Date::Utility->new($first_added), Date::Utility->new($last_added));
}

sub _add_ticks_for_epoch {
    my ($self, $args) = @_;

    my $retval = 0;

    if (@{$args->{ticks}}) {
        $retval = $self->add({
            underlying => $args->{underlying},
            epoch      => $args->{epoch},
            full_count => scalar(@{$args->{ticks}}),
            value      => $args->{ticks}[-1],
        });
    }

    return $retval;
}

sub _make_key {
    my ($self, $which, $extra) = @_;

    my $symbol = (ref $which eq 'BOM::Market::Underlying') ? $which->symbol : $which;
    return "AGGTICKS_${symbol}_" . $self->agg_interval->as_concise_string . ($extra ? '_UA' : '');
}

=head2 flush

Flush all keys associated with this object form the backing store.
With a provided symbol or underlying, flushes that one only.
This is exceptionally dangerous on a running site and should not be used unless you know why you are doing it.

=cut

sub flush {
    my ($self, $underlying) = @_;
    $underlying //= '*';    # Everything.

    my $redis = $self->_redis;

    my @keys = @{$redis->keys($self->_make_key($underlying))};
    push @keys, @{$redis->keys($self->_make_key($underlying, "ua"))};
    return @keys ? $redis->del(@keys) : 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
__END__

=head1 COPYRIGHT

Copyright (c) 2012 RMG Technology (M) Sdn. Bhd.

=cut
