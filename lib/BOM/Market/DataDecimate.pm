package BOM::Market::DataDecimate;

=head1 NAME

BOM::Market::DataDecimate

=head1 SYNOPSYS

    use BOM::Market::DataDecimate;

=head1 DESCRIPTION

A wrapper to let us use Redis to get decimated tick data.

=cut

use 5.010;
use Moose;

use BOM::Config::RedisReplicated;
use BOM::Config::Chronicle;

use Quant::Framework;
use List::Util qw( first min max );
use Quant::Framework::Underlying;
use Data::Decimate qw(decimate);
use Date::Utility;
use Sereal::Encoder;
use Sereal::Decoder;
use DataDog::DogStatsd::Helper qw(stats_gauge);
use Time::Duration::Concise;

sub get {
    my ($self, $args) = @_;

    my $decimate_flag = $args->{decimate} // 1;

    my $ticks;
    if ($decimate_flag) {
        $ticks = $self->decimate_cache_get($args);
    } else {
        $ticks = $self->tick_cache_get($args);
    }
    return $ticks;
}

sub decimate_cache_get {
    my ($self, $args) = @_;

    my $underlying = $args->{underlying};
    my $start_time = $args->{start_epoch};
    my $end_time   = $args->{end_epoch};
    my $backprice  = $args->{backprice} // 0;

    my $ticks;
    if ($backprice) {
        my $capped_end = $end_time - $self->decimate_retention_interval->seconds;
        $start_time = max($capped_end, $start_time);
        my $raw_ticks = $underlying->ticks_in_between_start_end({
            start_time => $start_time,
            end_time   => $end_time - ($end_time % $self->sampling_frequency->seconds),
        });

        my @rev_ticks = reverse @$raw_ticks;
        $ticks = Data::Decimate::decimate($self->sampling_frequency->seconds, \@rev_ticks);
    } else {
        $ticks = $self->_get_decimate_from_cache({
            symbol      => $underlying->symbol,
            start_epoch => $start_time,
            end_epoch   => $end_time,
        });
    }
    return $ticks;
}

sub tick_cache_get {
    my ($self, $args) = @_;

    my $underlying = $args->{underlying};
    my $start_time = $args->{start_epoch};
    my $end_time   = $args->{end_epoch};
    my $backprice  = $args->{backprice} // 0;

    my $ticks;
    if ($backprice) {
        my $capped_end = $end_time - $self->raw_retention_interval->seconds;
        $start_time = max($capped_end, $start_time);
        my $raw_ticks = $underlying->ticks_in_between_start_end({
            start_time => $start_time,
            end_time   => $end_time,
        });
        my @rev_ticks = reverse @$raw_ticks;
        $ticks = \@rev_ticks;
    } else {
        $ticks = $self->_get_raw_from_cache({
            symbol      => $underlying->symbol,
            start_epoch => $start_time,
            end_epoch   => $end_time,
        });
    }

    return $ticks;
}

sub tick_cache_get_num_ticks {
    my ($self, $args) = @_;

    my $underlying = $args->{underlying};
    my $num        = $args->{num};
    my $end_time   = $args->{end_epoch};
    my $start_time = $args->{start_epoch};
    my $backprice  = $args->{backprice} // 0;

    if ($backprice) {
        return $end_time ? $underlying->ticks_in_between_end_limit({
                end_time => $end_time,
                limit    => $num,
            }
            ) : $start_time ? $underlying->ticks_in_between_start_limit({
                start_time => $start_time,
                limit      => $num,
            }) : [];
    }

    return $self->_get_num_data_from_cache({
        symbol => $underlying->symbol,
        ($end_time ? (end_epoch => $end_time) : $start_time ? (start_epoch => $start_time) : ()),
        num => $num,
    });
}

=head2 sampling_frequency

=head2 data_cache_size

=head2 decimate_cache_size

=cut

has sampling_frequency => (
    is      => 'ro',
    isa     => 'Time::Duration::Concise',
    default => sub {
        Time::Duration::Concise->new(interval => '15s');
    },
);

# size is the number of ticks
has data_cache_size => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_data_cache_size',
);

sub _build_data_cache_size {
    my $self = shift;

# We added 1 min here as a buffer,
# Now both forex and volidx is 31 mins.
    my $cache_size = 31 * 60;

    return $cache_size;
}

has decimate_cache_size => (
    is      => 'ro',
    default => 2880,
);

has decimate_retention_interval => (
    is      => 'ro',
    isa     => 'Time::Duration::Concise',
    lazy    => 1,
    builder => '_build_decimate_retention_interval',
);

sub _build_decimate_retention_interval {
    my $self = shift;
    my $interval = int($self->decimate_cache_size / (60 / $self->sampling_frequency->seconds));
    return Time::Duration::Concise->new(interval => $interval . 'm');
}

has raw_retention_interval => (
    is      => 'ro',
    isa     => 'Time::Duration::Concise',
    lazy    => 1,
    builder => '_build_raw_retention_interval',
);

sub _build_raw_retention_interval {
    my $interval = int(shift->data_cache_size / 60);
    return Time::Duration::Concise->new(interval => $interval . 'm');
}

has decoder => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_decoder',
);

sub _build_decoder {
    return Sereal::Decoder->new;
}

has encoder => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_encoder',
);

sub _build_encoder {
    return Sereal::Encoder->new({
        canonical => 1,
    });
}

has 'redis_read' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_redis_read {
    return BOM::Config::RedisReplicated::redis_read();
}

has 'redis_write' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_redis_write {
    return BOM::Config::RedisReplicated::redis_write();
}

=head1 SUBROUTINES/METHODS
=head2 _make_key
=cut

sub _make_key {
    my ($self, $symbol, $decimate) = @_;

    my @bits = ("DECIMATE", $symbol);
    if ($decimate) {
        push @bits, ($self->sampling_frequency->as_concise_string, 'DEC');
    } else {
        push @bits, ($self->raw_retention_interval->as_concise_string, 'FULL');
    }

    return join('_', @bits);
}

=head2 _update
=cut 

sub _update {
    my ($self, $redis, $key, $score, $value) = @_;

    return $redis->zadd($key, $score, $value);
}

=head2 clean_up_raw

Clean up old feed-raw data up to end_epoch - retention interval. For raw feed, retention interval is 31m for forex and 5h for volidx.
	
=cut	

sub clean_up_raw {
    my ($self, $key, $end_epoch) = @_;

    $self->redis_write->zremrangebyscore($key, 0, $end_epoch - $self->raw_retention_interval->seconds);

    stats_gauge('feed_raw.count.' . $key, $self->redis_write->zcard($key));
    return undef;
}

=head2 clean_up_decimate   

Clean up old feed-decimate data up to end_epoch - retention interval. For decimate feed, retention interval is 12h.

=cut    

sub clean_up_decimate {
    my ($self, $key, $end_epoch) = @_;

    $self->redis_write->zremrangebyscore($key, 0, $end_epoch - $self->decimate_retention_interval->seconds);

    stats_gauge('feed_decimate.count.' . $key, $self->redis_write->zcard($key));
    return undef;
}

=head2 _get_decimate_from_cache

Get decimated data from cache.

=cut

sub _get_decimate_from_cache {
    my ($self, $args) = @_;

    my $which = $args->{symbol};
    my $start = $args->{start_epoch};
    my $end   = $args->{end_epoch};

    my $redis = $self->redis_read;

    my $key = $self->_make_key($which, 1);
    my @res = map { $self->decoder->decode($_) } @{$redis->zrangebyscore($key, $start, $end)};

    return \@res;
}

=head2 _get_raw_from_cache
Retrieve datas from start epoch till end epoch .
=cut

sub _get_raw_from_cache {
    my ($self, $args) = @_;
    my $symbol = $args->{symbol};
    my $start  = $args->{start_epoch};
    my $end    = $args->{end_epoch};

    my @res = map { $self->decoder->decode($_) } @{$self->redis_read->zrangebyscore($self->_make_key($symbol, 0), $start, $end)};

    return \@res;
}

=head2 _get_num_data_from_cache
Retrieve num number of data from DataCache.
=cut

sub _get_num_data_from_cache {

    my ($self, $args) = @_;

    my $symbol = $args->{symbol};
    my $end    = $args->{end_epoch};
    my $start  = $args->{start_epoch};
    my $num    = $args->{num};

    my $ticks =
          $end ? $self->redis_read->zrevrangebyscore($self->_make_key($symbol, 0), $end, 0, 'LIMIT', 0, $num)
        : $start ? $self->redis_read->zrangebyscore($self->_make_key($symbol, 0), $start, '+inf', 'LIMIT', 0, $num)
        :          [];

    @$ticks = reverse @$ticks if $end;
    my @res = map { $self->decoder->decode($_) } @$ticks;

    return \@res;
}

=head2 data_cache_insert_insert_raw 
=cut

sub data_cache_insert_raw {
    my ($self, $data) = @_;

    $data = $data->as_hash if blessed($data);

    my %to_store = %$data;

    $to_store{count} = 1;    # These are all single data;
    my $key = $self->_make_key($to_store{symbol}, 0);

    $self->_update($self->redis_write, $key, $data->{epoch}, $self->encoder->encode(\%to_store));
    $self->clean_up_raw($key, $to_store{epoch});

    return undef;
}

=head2 data_cache_insert_insert_decimate
=cut

sub data_cache_insert_decimate {
    my ($self, $symbol, $boundary) = @_;

    my $raw_key      = $self->_make_key($symbol, 0);
    my $decimate_key = $self->_make_key($symbol, 1);

    if (
        my @datas =
        map { $self->decoder->decode($_) }
        @{$self->redis_read->zrangebyscore($raw_key, $boundary - ($self->sampling_frequency->seconds - 1), $boundary)})
    {
        #do resampling
        my $decimate_data = Data::Decimate::decimate($self->sampling_frequency->seconds, \@datas);

        foreach my $tick (@$decimate_data) {
            $self->_update($self->redis_write, $decimate_key, $tick->{decimate_epoch}, $self->encoder->encode($tick));
        }
    } elsif (
        my @decimate_data = map {
            $self->decoder->decode($_)
        } reverse @{$self->redis_read->zrevrangebyscore($decimate_key, $boundary - $self->sampling_frequency->seconds, 0, 'LIMIT', 0, 1)})
    {
        my $single_data = $decimate_data[0];
        $single_data->{decimate_epoch} = $boundary;
        $single_data->{count}          = 0;
        my $time_diff = $boundary - $single_data->{epoch};

        stats_gauge('feed_decimate.time_diff.' . $decimate_key, $time_diff);

        my $update = ($time_diff > $self->raw_retention_interval->seconds) ? 0 : 1;
        $self->_update($self->redis_write, $decimate_key, $single_data->{decimate_epoch}, $self->encoder->encode($single_data)) if $update;
    }

    $self->clean_up_decimate($decimate_key, $boundary);

    return undef;
}

=head2 get_latest_tick_epoch
=cut

sub get_latest_tick_epoch {
    my ($self, $symbol, $decimated, $start, $end) = @_;

    my $key = $self->_make_key($symbol, $decimated);

    my $last_tick_epoch = do {
        my $timestamp     = 0;
        my $redis         = $self->redis_read;
        my $earlier_ticks = $redis->zcount($key, '-inf', $start);

        if ($earlier_ticks) {
            my @ticks = map { $self->decoder->decode($_) } @{$redis->zrevrangebyscore($key, $end, $start, 'LIMIT', 0, 100)};
            my $non_zero_tick = first { $_->{count} > 0 } @ticks;
            if ($non_zero_tick) {
                $timestamp = $decimated ? $non_zero_tick->{decimate_epoch} : $non_zero_tick->{epoch};
            }
        }
        $timestamp;
    };

    return $last_tick_epoch;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
