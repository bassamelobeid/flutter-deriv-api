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

use Cache::RedisDB;
use Date::Utility;
use List::Util qw( first min max );
use Time::Duration::Concise;
use Scalar::Util qw( blessed );
use Sereal::Encoder;
use Sereal::Decoder;

my $encoder = Sereal::Encoder->new({
    protocol_version => 2,
    canonical        => 1,
});
my $decoder = Sereal::Decoder->new;

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

=head2 unagg_retention_interval

A Time::Duration::Concise representing the time to hold unaggregated ticks.

=cut

has unagg_retention_interval => (
    is      => 'ro',
    isa     => 'bom_time_interval',
    default => '31m',
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

=head2  agg_retention_interval

A Time::Duration::Concise representing the total time we wish to keep aggregated ticks, defaults to 24 hours.

=cut

has agg_retention_interval => (
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

Add tick data to the cache.

=cut

sub add {
    my ($self, $tick, $fast_insert) = @_;

    $tick = $tick->as_hash if blessed($tick);

    my %to_store = %$tick;

    my $key = $self->_make_key($to_store{symbol}, 0);
    $to_store{count} = 1;    # These are all single ticks;

    return _update($self->_redis, $key, $tick->{epoch}, $encoder->encode(\%to_store), $fast_insert);    # These are all single ticks.
}

=head2 retrieve

Return the aggregated tick data for an underlying over the last BOM:TimeInterval

=cut

sub retrieve {
    my ($self, $args) = @_;

    my $which      = $args->{underlying};
    my $ti         = $args->{interval} || $self->agg_retention_interval;
    my $end        = $args->{ending_epoch} || time;
    my $fill_cache = $args->{fill_cache} // 1;
    my $aggregated = $args->{aggregated} // 1;

    my $agg_seconds = $self->agg_interval->seconds;
    my $redis       = $self->_redis;
    my @res;

    if (my $tc = $args->{tick_count}) {
        $self->fill_from_historical_feed($args) if ($fill_cache and $end < time - $self->unagg_retention_interval->seconds);
        @res = map { $decoder->decode($_) } reverse @{$redis->zrevrangebyscore($self->_make_key($which, 0), $end, 0, 'LIMIT', 0, $tc)};
    } else {
        my ($hold_secs, $key);
        if ($aggregated) {
            $hold_secs = $self->agg_retention_interval->seconds;
            $key = $self->_make_key($which, 1);
        } else {
            $hold_secs = $self->unagg_retention_interval->seconds;
            $key = $self->_make_key($which, 0);
        }

        my $start = $end - min($ti->seconds, $hold_secs);    # No requests for longer than the retention.
        $self->fill_from_historical_feed($args) if ($fill_cache and $start < time - ($hold_secs + $agg_seconds));

        @res = map { $decoder->decode($_) } @{$redis->zrangebyscore($key, $start, $end)};
        # We get the last tick for aggregated tick request.
        # Else, we will have missing information.
        if ($aggregated) {
            $args->{tick_count} = 1;
            my @latest = @{$self->retrieve($args)};
            push @res, $latest[0] if (@latest and @res and $latest[0]->{epoch} > $res[-1]->{agg_epoch});
        }
    }

    return \@res;
}

=head2 aggregate_for

Aggregate current unaggregated ticks for the supplied underlying to the epoch supplied

    $at->aggregate_for(underlying => $underlying, ending_epoch => $epoch});

=cut

sub aggregate_for {
    my ($self, $args) = @_;

    my $ul          = $args->{underlying};
    my $end         = $args->{ending_epoch} || time;
    my $fast_insert = $args->{fast_insert};
    my $ai          = $self->agg_interval;
    my $last_agg    = $end - ($end % $ai->seconds);

    my ($total_added, $first_added, $last_added) = (0, 0, 0);
    my $redis = $self->_redis;
    my ($unagg_key, $agg_key) = map { $self->_make_key($ul, $_) } (0 .. 1);
    my $count = 0;

    if (my @ticks = map { $decoder->decode($_) } @{$redis->zrangebyscore($unagg_key, 0, $last_agg)}) {
        my $first_tick = $ticks[0];
        my $prev_tick  = $first_tick;
        my $offset     = $first_tick->{epoch} % $ai->seconds;
        my $prev_agg   = $first_tick->{epoch} - $offset;
        shift @ticks unless $offset;    # Caught tail end of previous period.
        my $next_agg   = $prev_agg + $ai->seconds;
        my $tick_count = 0;

        foreach my $tick (@ticks) {
            if ($tick->{epoch} == $next_agg) {
                $first_added ||= $next_agg;
                $last_added        = $next_agg;
                $tick->{count}     = $tick_count + 1;
                $tick->{agg_epoch} = $next_agg;
                $total_added++;
                _update($redis, $agg_key, $next_agg, $encoder->encode($tick), $fast_insert);
                $tick_count = 0;
                $next_agg += $ai->seconds;
            } elsif ($tick->{epoch} > $next_agg) {
                $tick_count++ if $first_added;    # We count this tick, too unless we are just starting out.
                while ($tick->{epoch} > $next_agg) {
                    $first_added ||= $next_agg;
                    $last_added             = $next_agg;
                    $prev_tick->{count}     = $tick_count;
                    $prev_tick->{agg_epoch} = $next_agg;
                    $total_added++;
                    _update($redis, $agg_key, $next_agg, $encoder->encode($prev_tick), $fast_insert);
                    $next_agg += $ai->seconds;
                    $tick_count = 0;
                    unshift @ticks, $tick if ($tick->{epoch} == $next_agg);    # Let the above code handle this.
                }
            } else {
                # Skipped.
                $tick_count++;
            }

            $prev_tick = $tick;
        }

        # While we are here, clean up any particularly old stuff
        $redis->zremrangebyscore($unagg_key, 0, $end - $self->unagg_retention_interval->seconds);
        $redis->zremrangebyscore($agg_key,   0, $end - $self->agg_retention_interval->seconds);
    }

    return ($total_added, Date::Utility->new($first_added), Date::Utility->new($last_added));
}

sub _update {
    my ($redis, $key, $score, $value, $fast_insert) = @_;

    $redis->zremrangebyscore($key, $score, $score) unless ($fast_insert);
    return $redis->zadd($key, $score, $value);
}

=head2 fill_from_historical_feed

Gather known ticks from the past

    $at->fill_from_historical_feed({underlying => $underlying, [ending_epoch => $epoch, interval => $interval]});

Intervals longer than the retention interval will be shortened to the retention interval

=cut

sub fill_from_historical_feed {
    my ($self, $args) = @_;

    my $underlying     = $args->{underlying};
    my $end            = $args->{ending_epoch} || time;
    my $fill_interval  = $args->{interval} // $self->agg_retention_interval;
    my $fast_insert    = $args->{fast_insert};
    my $agg_interval   = $self->agg_interval;
    my $unagg_interval = $self->unagg_retention_interval;

    my $start = $end - min($fill_interval->seconds, $self->agg_retention_interval->seconds);
    $start = $start - $start % $agg_interval->seconds;
    my $first_agg = $start - $agg_interval->seconds;

    # try to speed up a bit, i.e. do not re-insert whole ticks array in the specified timeframe,
    # but lets try shift the starting border to end as much as possible, i.e. to the
    # latest already inserted into redis tick
    my $last_non_zero_aggtick = do {
        my $timestamp = 0;
        # Ticks are inserated into _AGG set later than  into _FULL. Hence, to we fetch lastly inserted
        # in the case of die in in the middle.
        my $agg_key       = $self->_make_key($underlying, 1);
        my $redis         = $self->_redis;
        my @ticks         = map { $decoder->decode($_) } @{$redis->zrevrangebyscore($agg_key, $end, $first_agg, 'LIMIT', 0, 100)};
        my $non_zero_tick = first { $_->{count} > 0 } @ticks;
        if ($non_zero_tick) {
            $timestamp = $non_zero_tick->{agg_epoch};
        }
        $timestamp;
    };
    $first_agg = max($first_agg, $last_non_zero_aggtick);

    my $ticks = $args->{ticks} // $underlying->ticks_in_between_start_end({
        start_time => $first_agg,
        end_time   => $end,
    });

    # First add all the found ticks.
    foreach my $tick (@$ticks) {
        $self->add($tick, $fast_insert);
    }

    # Now aggregate to the right point in time.
    return $self->aggregate_for({
        underlying   => $underlying,
        ending_epoch => $end,
        fast_insert  => $fast_insert,
    });
}

sub _make_key {
    my ($self, $which, $agg) = @_;

    my $symbol = (ref $which eq 'BOM::Market::Underlying') ? $which->symbol : $which;
    my @bits = ("AGGTICKS", $symbol);
    if ($agg) {
        push @bits, ($self->agg_interval->as_concise_string, 'AGG');
    } else {
        push @bits, ($self->unagg_retention_interval->as_concise_string, 'FULL');
    }

    return join('_', @bits);
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

    my @keys = (map { @{$redis->keys($self->_make_key($underlying, $_))} } (0 .. 1));

    return @keys ? $redis->del(@keys) : 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
__END__

=head1 COPYRIGHT

Copyright (c) 2012 RMG Technology (M) Sdn. Bhd.

=cut
