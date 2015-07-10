package BOM::Market::TickCache;

=head1 NAME

BOM::Market::TickCache

=head1 SYNOPSYS

    use BOM::Market::TickCache;

=head1 DESCRIPTION

A wrapper to let us use Redis SortedSets to get cached tick data.

=cut

use 5.010;
use Moose;
use Carp;

use Cache::RedisDB;
use Date::Utility;
use ExpiryQueue qw( update_queue_for_tick );
use List::Util qw(min);
use Time::Duration::Concise;
use Scalar::Util qw(blessed);
use Sereal::Decoder;
use Sereal::Encoder;

use BOM::Market::Underlying;

=head2 retention_interval

A Time::Duration::Concise representing the total time we wish to keep ticks, defaults to 2 hours.

=cut

has retention_interval => (
    is      => 'ro',
    isa     => 'bom_time_interval',
    default => '2h',
    coerce  => 1,
);

# We'll just piggy back off Cache::RedisDB's knowledge of Redis.
sub _redis {
    return Cache::RedisDB->redis;
}

=head2 add

Add tick data to the cache.

=cut

my $enc = Sereal::Encoder->new({protocol_version => 2});
my $dec = Sereal::Decoder->new;

sub add {
    my ($self, $tick) = @_;

    if (not blessed($tick)) {
        # Assume it is a hashref from feed client
        $tick = BOM::Market::Data::Tick->new($tick);
    }

    update_queue_for_tick($tick);

    return $self->_redis->zadd($self->_make_key($tick->symbol), $tick->epoch, $enc->encode($tick));
}

=head2 retrieve

Return the tick data for an underlying over a BOM:TimeInterval or some count

=cut

sub retrieve {
    my ($self, $args) = @_;

    my $which      = $args->{underlying};
    my $fill_cache = $args->{fill_cache} // 1;
    my $ti         = $args->{interval} // $self->retention_interval;
    my $count      = $args->{latest};
    my $end        = $args->{ending_epoch} // time;

    my $redis = $self->_redis;
    my $key   = $self->_make_key($which);
    my @res;

    if ($count) {
        if ($fill_cache and $end < time - $self->retention_interval->seconds) {
            $self->fill_from_historical_feed({
                underlying   => $which,
                ending_epoch => $end,
                interval     => $ti,
            });
        }
        @res = reverse @{$redis->execute('ZREVRANGEBYSCORE', $key, $end, 0, 'LIMIT', 0, $count)};
    } else {
        $ti = $self->retention_interval if ($ti->seconds > $self->retention_interval->seconds);
        my $start = $end - $ti->seconds;
        if ($fill_cache and $start < time - $self->retention_interval->seconds) {
            $self->fill_from_historical_feed({
                underlying   => $which,
                ending_epoch => $end,
                interval     => $ti,
            });
        }
        @res = @{$redis->zrangebyscore($key, $start, $end)};
    }

    return [map { $dec->decode($_) } @res];
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
    my $secs_back =
          $args->{interval}
        ? $args->{interval}->seconds
        : $self->retention_interval->seconds;

    my $tick_data = $underlying->ticks_in_between_start_end({
        start_time => $end - $secs_back,
        end_time   => $end,
    });

    my @ordered_tick_data = reverse @$tick_data;

    my $added       = scalar @ordered_tick_data;
    my $first_added = ($added) ? $ordered_tick_data[0]->epoch : 0;
    my $last_added  = ($added) ? $ordered_tick_data[-1]->epoch : 0;

    TICK:
    while (my $tick = shift @ordered_tick_data) {
        $self->add($tick);
    }

    return ($added, Date::Utility->new($first_added), Date::Utility->new($last_added));
}

sub _make_key {
    my ($self, $which, $extra) = @_;

    my $symbol = (ref $which eq 'BOM::Market::Underlying') ? $which->symbol : $which;
    return 'TICK_CACHE_' . $symbol . '_' . $self->retention_interval->as_concise_string;
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
    return @keys ? $redis->del(@keys) : 0;
}

=head2 prune

Prune all keys associated with this object to containonly the latest ticks; back to the start
of the retention interval

With a provided symbol or underlying, prunes that one only.

=cut

sub prune {
    my ($self, $underlying) = @_;

    $underlying //= '*';    # Everything.

    my $redis = $self->_redis;
    my $key   = $self->_make_key($underlying);
    my $then  = time - ($self->retention_interval->seconds + 1);

    return $redis->zremrangebyscore($key, 0, $then);
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
__END__

=head1 COPYRIGHT

Copyright (c) 2012 RMG Technology (M) Sdn. Bhd.

=cut
