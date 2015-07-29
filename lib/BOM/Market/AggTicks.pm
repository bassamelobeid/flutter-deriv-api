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
use ExpiryQueue qw( update_queue_for_tick );
use List::Util qw( min );
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
    default => '15m',
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
    my ($self, $tick) = @_;

    $tick = $tick->as_hash if blessed($tick);

    my %to_store = %$tick;

    my $key = $self->_make_key($to_store{symbol}, 0);
    my $redis = $self->_redis;

    update_queue_for_tick(\%to_store);
    $to_store{count} = 1;    # These are all single ticks;

    return $self->_update($key, $tick->{epoch}, $encoder->encode(\%to_store));    # These are all single ticks.
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
        @res = map { $decoder->decode($_) } reverse @{$redis->execute('ZREVRANGEBYSCORE', $self->_make_key($which, 0), $end, 0, 'LIMIT', 0, $tc)};
    } else {
        my ($interval_to_check, $key);
        if ($aggregated) {
            $interval_to_check = 'agg_retention_interval';
            $key = $self->_make_key($which, 1);
        } else {
            $interval_to_check = 'unagg_retention_interval';
            $key = $self->_make_key($which, 0);
        }

        my $start = $end - $ti->seconds;
        $self->fill_from_historical_feed($args) if ($fill_cache and $start < time - $self->$interval_to_check->seconds);

        @res = map { $decoder->decode($_) } @{$redis->zrangebyscore($key, $start, $end)};
        # We get the last tick for aggregated tick request.
        # Else, we will have missing information.
        if ($aggregated) {
            my @latest = @{$self->retrieve({%$args, tick_count => 1})};
            push @res, $latest[0] if (@latest and @res and $latest[0]->{epoch} > $res[-1]->{epoch});
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

    my $ul       = $args->{underlying};
    my $end      = $args->{ending_epoch} || time;
    my $ai       = $self->agg_interval;
    my $last_agg = $end - ($end % $ai->seconds);

    my ($total_added, $first_added, $last_added) = (0, 0, 0);
    my $redis = $self->_redis;
    my ($unagg_key, $agg_key) = map { $self->_make_key($ul, $_) } (0 .. 1);
    my $count = 0;

    if (my @ticks = map { $decoder->decode($_) } @{$redis->zrangebyscore($unagg_key, 0, $last_agg)}) {
        my $first_tick = $ticks[0];
        my $prev_tick  = $first_tick;
        my $offset = $first_tick->{epoch} % $ai->seconds;
        my $prev_agg   = $first_tick->{epoch} - $offset;
        shift @ticks unless $offset; # Caught tail end of previous period.
        my $next_agg   = $prev_agg + $ai->seconds;
        my $tick_count = 0;

        foreach my $tick (@ticks) {
            if ($tick->{epoch} == $next_agg) {
                $first_added //= $next_agg;
                $last_added = $next_agg;
                $tick->{count} = $tick_count + 1;
                $tick->{agg_epoch} = $next_agg;
                $total_added++;
                $self->_update($agg_key, $next_agg, $encoder->encode($tick));
                $tick_count = 0;
                $next_agg += $ai->seconds;
            } elsif ($tick->{epoch} > $next_agg) {
                while ($tick->{epoch} > $next_agg) {
                    $first_added //= $next_agg;
                    $last_added             = $next_agg;
                    $prev_tick->{count}     = $tick_count;
                    $prev_tick->{agg_epoch} = $next_agg;
                    $total_added++;
                    $self->_update($agg_key, $next_agg, $encoder->encode($prev_tick));
                    $next_agg += $ai->seconds;
                    $tick_count = 0;
                    unshift @ticks, $tick if ($tick->{epoch} == $next_agg); # Let the above code handle this.
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
    my ($self, $key, $score, $value) = @_;

    my $redis = $self->_redis;
    $redis->zremrangebyscore($key, $score, $score);
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
    my $agg_interval   = $self->agg_interval;
    my $unagg_interval = $self->unagg_retention_interval;

    my $start = $end - min($fill_interval->seconds, $self->agg_retention_interval->seconds);
    $start = $start - $start % $agg_interval;
    my $first_agg = $start - $agg_interval;

    my $ticks = $args->{ticks} // $underlying->ticks_in_between_start_end({
        start_time => $first_agg,
        end_time   => $end,
    });

    # First add all the found ticks.
    foreach my $tick (@$ticks) {
        $self->add($tick);
    }

    # Now aggregate to the right point in time.
    return $self->aggregate_for({
        underlying   => $underlying,
        ending_epoch => $end
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
