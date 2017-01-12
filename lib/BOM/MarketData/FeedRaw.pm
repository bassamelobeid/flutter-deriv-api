package BOM::MarketData::FeedRaw;

use 5.010;
use strict;
use warnings;

=head1 NAME

BOM::MarketData::FeedRaw

=head1 SYNOPSIS

use BOM::MarketData::FeedRaw

=head1 DESCRIPTION

This is daemon that connects to the feed distributor, receives ticks, and publishes it into redis 'feed'
channel.

=cut

use Moo;
use namespace::autoclean;
use ZMQ::Constants qw(ZMQ_SUB ZMQ_SUBSCRIBE ZMQ_NOBLOCK ZMQ_POLLIN);
use ZMQ::LibZMQ3;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::MarketData qw(create_underlying_db);
use BOM::System::Config;
use Try::Tiny;
use BOM::Platform::Runtime;
use YAML::XS 0.35;
use POSIX qw(:errno_h);
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);
use ExpiryQueue qw( update_queue_for_tick );
use Time::HiRes;
use List::Util qw(first max);

use Data::Decimate qw(decimate);
use BOM::Market::DataDecimate;

has timeout => (
    is       => 'ro',
    required => 1
);

has feed_distributor => (
    is       => 'ro',
    required => 1
);

has _zmq_context => (is => 'rw');
has _zmq_socket  => (is => 'rw');

sub BUILD {
    # initialize zero-mq
    my $self = shift;
    my ($host, $port) = split ':', $self->feed_distributor;

    my $ctx = zmq_init(1) or die "Couldn't create ZMQ context: $!";
    my $sock = zmq_socket($ctx, ZMQ_SUB)
        or die "Couldn't create ZMQ socket: $!";
    zmq_connect($sock, "tcp://$host:$port") == 0
        or die("Couldn't connect to feed-distributor at $host:$port");
    zmq_setsockopt($sock, ZMQ_SUBSCRIBE, '') == 0
        or die("Couldn't subscribe: $!");
    $self->_zmq_context($ctx);
    $self->_zmq_socket($sock);

    my $decimate_cache = BOM::Market::DataDecimate->new();

    my @uls = map { create_underlying($_) } create_underlying_db->symbols_for_intraday_fx;

#back populate
    my $end = time;
    my $start = $end - (30 * 60);

    foreach my $ul (@uls) {
        my $raw_key = $decimate_cache->_make_key($ul->symbol, 0);

        my $last_raw_tick = do {
            my $timestamp     = 0;
            my $redis         = $decimate_cache->redis_read;
            my $earlier_ticks = $redis->zcount($raw_key, '-inf', $start);

            if ($earlier_ticks) {
                my @ticks = map { $decimate_cache->decoder->decode($_) } @{$redis->zrevrangebyscore($raw_key, $end, $start, 'LIMIT', 0, 100)};
                my $non_zero_tick = first { $_->{count} > 0 } @ticks;
                if ($non_zero_tick) {
                    $timestamp = $non_zero_tick->{epoch};
                }
            }
            $timestamp;
        };
        my $last_raw_epoch = max($start, $last_raw_tick);

        my $ticks = $ul->ticks_in_between_start_end({
            start_time => $last_raw_epoch,
            end_time   => $end,
        });

        foreach my $single_data (@$ticks) {
            $decimate_cache->_update($decimate_cache->redis_write, $raw_key, $single_data->{epoch}, $decimate_cache->encoder->encode($single_data));
        }

    }
    return;
}

sub DEMOLISH {
    # shut down zero-mq
    my $self = shift;
    zmq_close($self->_zmq_socket);
    zmq_term($self->_zmq_context);
    return;
}

sub _process_incoming_messages {
    my ($self, $zmq) = @_;
    state $ticks_count;
    my %symbols_to_decimate = map { $_ => 1 } create_underlying_db->symbols_for_intraday_fx;

    while (my $msg = zmq_recvmsg($zmq, ZMQ_NOBLOCK)) {
        my $tick_yml  = zmq_msg_data($msg);
        my $tick      = try { Load($tick_yml) };
        my $timestamp = delete $tick->{timestamp};
        stats_timing('feed.decimate.client_entry', int(1000 * (Time::HiRes::time - $timestamp)))
            if $timestamp;
        zmq_msg_close($msg);
        next unless $tick;    # invalid yaml

        $tick = _cleanup_tick($tick);

        $self->_tick_source->data_cache_insert_raw($tick) if $symbols_to_decimate{$tick->{symbol}};

    }

    # last zmq_recv should have set errno to EAGAIN, it also may be EINTR,
    # if it is something else we should die
    unless ($! == EAGAIN or $! == EINTR) {
        warn("zmq_recv returned error: $!");
        exit(-1);
    }

    return;
}

sub iterate {
    my $self    = shift;
    my $zmq     = $self->_zmq_socket;
    my $timeout = $self->timeout * 1000;
    my $success = 1;

    my $rv = zmq_poll([{
                socket   => $zmq,
                events   => ZMQ_POLLIN,
                callback => sub { _process_incoming_messages($self, $zmq) },
            }
        ],
        $timeout
    );

    # if we didn't get anything for quite a long time,
    # it is possible that connection has stalled
    unless ($rv > 0) {
        warn("zmq_poll returned an error: $!") if $rv < 0;
        warn("Haven't got any messages from ZMQ in ${timeout} microseconds") unless $ENV{BOM_SUPPRESS_WARNINGS};
        $success = 0;
    }

    return $success;
}

# removes extra fields from tick to save into redis and pass to
# B::FM::Data::Tick constructor
sub _cleanup_tick {
    my $tick       = shift;
    my $clean_tick = {};
    @$clean_tick{qw(epoch symbol quote bid ask)} = @$tick{qw(epoch symbol quote bid ask)};

    # Temporal hack, as our infrastructure does not supports yet ticks with more then 1Hz
    # frequencies. Such a ticks aren't published yet, but our volatilities (R_100, etc.)
    # already provide epoch with millisecond precision. So, we need that for temporally
    # for backward-compatibility

    $clean_tick->{epoch} = int($tick->{epoch});
    return $clean_tick;
}

has _tick_source => (
    is      => 'ro',
    default => sub {
        BOM::Market::DataDecimate->new;
    },
);

1;
