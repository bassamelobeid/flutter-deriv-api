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

use BOM::Config::Redis;
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

use constant SPOT_SEPARATOR => '::';

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

sub spot_min_max {
    my ($self, $args) = @_;

    # THE RELEASE NEEDS TO BE BACKWARD COMPATIBLE.
    # TRELLO: https://trello.com/c/zh59tmHk
    #
    # IT TAKES 12h FOR FEED-POPULATOR TO FILL THE NEW FORMAT,
    # ONCE THAT IS DONE, A FOLLOW UP CARD WILL UNCOMMENT BELOW SNIPPET.

    #################################### START UNCOMMENT
    # my $use_decimate = $args->{decimate} // 1;
    # unless ($args->{backprice}) {
    #     my $symbol   = $args->{underlying}->symbol;
    #     my $start    = $args->{start_epoch};
    #     my $end      = $args->{end_epoch};
    #     my $key_spot = $self->_make_key($symbol, $use_decimate, 1);

    #     my @quotes = sort { $a <=> $b } map {
    #         my ($quote, undef) = split SPOT_SEPARATOR;
    #         $quote
    #     } @{$self->redis_read->zrangebyscore($key_spot, $start, $end)};

    #     return [$quotes[0], $quotes[-1]];
    # }
    #################################### END UNCOMMENT

    my $ticks  = $self->get($args);
    my @quotes = map { $_->{quote} } @$ticks;
    return [min(@quotes), max(@quotes)];
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

has sampling_frequency => (
    is      => 'ro',
    isa     => 'Time::Duration::Concise',
    default => sub { return Time::Duration::Concise->new(interval => '15s'); });

has decimate_retention_interval => (
    is      => 'ro',
    isa     => 'Time::Duration::Concise',
    default => sub { return Time::Duration::Concise->new(interval => '12h'); });

has raw_retention_interval => (
    is      => 'ro',
    isa     => 'Time::Duration::Concise',
    default => sub { return Time::Duration::Concise->new(interval => '31m'); });

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
    return BOM::Config::Redis::redis_replicated_read();
}

has 'redis_write' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_redis_write {
    return BOM::Config::Redis::redis_replicated_write();
}

=head1 SUBROUTINES/METHODS
=head2 _make_key
=cut

sub _make_key {
    my ($self, $symbol, $is_decimate, $is_spot) = @_;
    my $interval =
          $is_decimate
        ? $self->sampling_frequency->as_concise_string
        : $self->raw_retention_interval->as_concise_string;
    my @bits = ('DECIMATE', $symbol, $interval, $is_decimate ? 'DEC' : 'FULL');
    # we keep two redis zsets, one containting the tick object (_FULL, _DEC),
    # and another containting only the "spot" value (_FULL_SPOT, _DEC_SPOT).
    # queyring and decoding the second one is faster.
    push @bits, 'SPOT' if $is_spot;
    return join('_', @bits);
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
          $end   ? $self->redis_read->zrevrangebyscore($self->_make_key($symbol, 0), $end, 0, 'LIMIT', 0, $num)
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

    my $tick = {%$data};
    $tick->{count} //= 1;    # These are all single data;

    $self->_upsert($tick->{symbol}, $tick, 0);
    $self->_clean_up($tick->{symbol}, $tick->{epoch}, 0);

    return undef;
}

sub data_cache_back_populate_raw {
    my ($self, $symbol, $ticks) = @_;

    foreach my $tick (@$ticks) {
        $tick = $tick->as_hash if blessed($tick);
        $self->_upsert($symbol, $tick, 0);
    }
    return undef;
}

=head2 data_cache_insert_insert_decimate
=cut

sub data_cache_insert_decimate {
    my ($self, $symbol, $boundary) = @_;

    my $key_raw      = $self->_make_key($symbol, 0, 0);
    my $key_decimate = $self->_make_key($symbol, 1, 0);

    if (
        my @datas =
        map { $self->decoder->decode($_) }
        @{$self->redis_read->zrangebyscore($key_raw, $boundary - ($self->sampling_frequency->seconds - 1), $boundary)})
    {
        #do resampling
        my $decimate_data = Data::Decimate::decimate($self->sampling_frequency->seconds, \@datas);

        foreach my $tick (@$decimate_data) {
            $self->_upsert($symbol, $tick, 1);
        }
    } elsif (
        my @decimate_data =
        map { $self->decoder->decode($_) }
        reverse @{$self->redis_read->zrevrangebyscore($key_decimate, $boundary - $self->sampling_frequency->seconds, 0, 'LIMIT', 0, 1)})
    {
        my $single_data = $decimate_data[0];
        $single_data->{decimate_epoch} = $boundary;
        $single_data->{count}          = 0;
        my $time_diff = $boundary - $single_data->{epoch};

        stats_gauge('feed_decimate.time_diff.' . $key_decimate, $time_diff);

        my $update = ($time_diff > $self->raw_retention_interval->seconds) ? 0 : 1;
        $self->_upsert($symbol, $single_data, 1) if $update;
    }

    $self->_clean_up($symbol, $boundary, 1);

    return undef;
}

sub data_cache_back_populate_decimate {
    my ($self, $symbol, $ticks) = @_;

    my @sorted_ticks  = sort { $a->{epoch} <=> $b->{epoch} } @$ticks;
    my $decimate_data = Data::Decimate::decimate($self->sampling_frequency->seconds, \@sorted_ticks);

    foreach my $single_data (@$decimate_data) {
        $self->_upsert($symbol, $single_data, 1);
    }
    return undef;
}

=head2 get_latest_tick_epoch
=cut

sub get_latest_tick_epoch {
    my ($self, $symbol, $decimated, $start, $end) = @_;

    my $key = $self->_make_key($symbol, $decimated, 0);

    my $last_tick_epoch = do {
        my $timestamp     = 0;
        my $redis         = $self->redis_read;
        my $earlier_ticks = $redis->zcount($key, '-inf', $start);

        if ($earlier_ticks) {
            my @ticks         = map { $self->decoder->decode($_) } @{$redis->zrevrangebyscore($key, $end, $start, 'LIMIT', 0, 100)};
            my $non_zero_tick = first { $_->{count} > 0 } @ticks;
            if ($non_zero_tick) {
                $timestamp = $decimated ? $non_zero_tick->{decimate_epoch} : $non_zero_tick->{epoch};
            }
        }
        $timestamp;
    };

    return $last_tick_epoch;
}

=head2 _upsert
update or insert
=cut 

sub _upsert {
    my ($self, $symbol, $tick_data, $is_decimate) = @_;

    my $tick = {%$tick_data};
    delete $tick->{ohlc};

    my $epoch = $is_decimate ? $tick->{decimate_epoch} : $tick->{epoch};

    my $key      = $self->_make_key($symbol, $is_decimate, 0);
    my $key_spot = $self->_make_key($symbol, $is_decimate, 1);

    my $value      = $self->encoder->encode($tick);
    my $value_spot = join(SPOT_SEPARATOR, $tick->{quote}, $epoch);

    $self->redis_write->zadd($key,      $epoch, $value);
    $self->redis_write->zadd($key_spot, $epoch, $value_spot);

    return undef;
}

=head2 _clean_up
Clean up old feed-raw or feed-decimate data up to end_epoch - retention interval.
raw-feed retention interval is 31m for forex and 5h for synthetic_index.
decimate-feed retention interval is 12h.
=cut

sub _clean_up {
    my ($self, $symbol, $end_epoch, $is_decimate) = @_;
    my $interval = $is_decimate ? $self->decimate_retention_interval->seconds : $self->raw_retention_interval->seconds;

    my $key      = $self->_make_key($symbol, $is_decimate, 0);
    my $key_spot = $self->_make_key($symbol, $is_decimate, 1);

    $self->redis_write->zremrangebyscore($key,      0, $end_epoch - $interval);
    $self->redis_write->zremrangebyscore($key_spot, 0, $end_epoch - $interval);
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
