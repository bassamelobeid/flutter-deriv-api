#!/usr/bin/env perl
use strict;
use warnings;

use DataDog::DogStatsd::Helper qw(stats_timing stats_gauge);
use Future::Utils              qw(fmap_void);
use List::Util                 qw(any min);
use IO::Async::Loop;
use Net::Async::Redis;
use Future::AsyncAwait;
use Log::Any          qw($log);
use Log::Any::Adapter qw(DERIV),
    stderr    => 'json',
    log_level => 'info';
use Getopt::Long;
use Algorithm::Backoff;
use Syntax::Keyword::Try;
use BOM::Config::Redis;

=head1 NAME queue_monitor.pl

Queue monitoring script.

=head1 SYNOPSIS

    perl queue_monitor.pl [--server rpc] [--redis redis://...]  [--stream general] [--stream multiple_stream...]

=cut

use constant XRANGE_BATCH_LIMIT         => 200;
use constant REDIS_CONNECTION_TIMEOUT   => 5;
use constant MONITOR_FAILURE_TTL        => 1800;
use constant MONITOR_FAILURE_KEY_PREFIX => 'MONITOR_FAILURE_';

my %REDIS_SERVER_DEFAULT = (
    events => {
        DEFAULT_STREAM => 'GENERIC_EVENTS_STREAM',
        METRIC_PREFIX  => 'bom_events.monitoring.'
    },
    rpc => {
        DEFAULT_STREAM => 'general',
        METRIC_PREFIX  => 'bom_rpc.v_3.monitoring.'
    });

GetOptions(
    'server=s'     => \(my $server = 'rpc'),
    'stream|s=s@'  => \(my $streams),
    'redis|r=s'    => \(my $redis_uri),
    'interval|i=i' => \(my $interval_in_seconds = 30),
) or die("Error in input arguments\n");

die "Invalid Redis server" unless any { $server eq $_ } keys %REDIS_SERVER_DEFAULT;

my $redis_config = BOM::Config::Redis::redis_config($server, 'read');
$redis_uri //= $redis_config->{uri};

my $redis_write_config = BOM::Config::Redis::redis_config($server, 'write');
my $redis_write_uri    = $redis_write_config->{uri};

$streams          //= [$REDIS_SERVER_DEFAULT{$server}->{DEFAULT_STREAM}] or die "DEFAULT_STREAM is missing.";
my $METRIC_PREFIX //= $REDIS_SERVER_DEFAULT{$server}->{METRIC_PREFIX}    or die "METRIC_PREFIX is missing.";

$log->info("Start running $server" . "_queue_monitor");
my $loop = IO::Async::Loop->new;
$loop->add(my $redis       = Net::Async::Redis->new(uri => $redis_uri,       auth => $redis_config->{password}));
$loop->add(my $redis_write = Net::Async::Redis->new(uri => $redis_write_uri, auth => $redis_write_config->{password}));

=head2 compare_id

Compare redis-style id of records, considering timestamps and then the following ids.
Also considers undef/empty values as the smaller value.

Redis Style IDs:
    <timestamp>-<id>

=over 4

=item * C<x> id for first record

=item * C<y> id for second record

=back

Acts similar to the <=> operator.

Returns 1 (x > y), -1 (y > x), 0 (x == y)

=cut

sub compare_id {
    my ($x, $y) = @_;
    # Handle either side being zero/undef/empty
    return -1 if $y  && !$x;
    return 1  if $x  && !$y;
    return 0  if !$x && !$y;
    # Do they match?
    return 0 if $x eq $y;
    my @first  = split /-/, $x, 2;
    my @second = split /-/, $y, 2;
    return $first[0] <=> $second[0]
        || $first[1] <=> $second[1];
}

async sub stream_metrics {
    my ($stream, $group_info) = @_;

    my ($redis_response) = await $redis->xinfo(STREAM => $stream);
    my %info = $redis_response->@*;

    my $last_delivered = $group_info->{'last-delivered-id'};
    my $group_name     = $group_info->{'name'};

    my $total = 0;
    if ($last_delivered and $last_delivered ne '0-0' and compare_id($last_delivered, $info{'first-entry'}[0]) > 0) {

        my ($direction, $endpoint, $limit) = ('xrange', '-', XRANGE_BATCH_LIMIT);
        {
            no warnings 'numeric';
            # We want to process as few items as possible, so we start at the closest end,
            # with the assumption that the items are evenly distributed
            # Data format is xxx-yyy, we really only care about the timestamp information
            # which is in epoch milliseconds as the xxx value
            if ($last_delivered - $info{'first-entry'}[0] > $info{'last-entry'}[0] - $last_delivered) {
                $direction = 'xrevrange';
                $endpoint  = '+';
            }
        }

        while (1) {
            my ($redis_response) = await $redis->$direction($stream, $endpoint, $last_delivered, COUNT => $limit);
            $total += @$redis_response;
            last unless @$redis_response >= $limit;
            # Overlapping ranges, so the next ID will be included twice
            --$total;
            $endpoint = $redis_response->[-1][0];
            await $loop->delay_future(after => 0.1);
        }
        $total = $info{length} - $total if $direction eq 'xrange';
    }

    stats_gauge($METRIC_PREFIX . 'queue.size', $total, {tags => ['stream:' . $stream, 'group:' . $group_name]});

    return;
}

# Tracking active stream_metrics queries - 2-level hash containing stream and group
my %active_stream_metrics;

async sub group_metrics {
    my ($stream) = @_;

    my $redis_response;
    try {
        # Only retry a failed stream once the TTL time has passed
        return if await $redis->get(MONITOR_FAILURE_KEY_PREFIX . $stream);

        ($redis_response) = await $redis->xinfo(GROUPS => $stream);
    } catch ($e) {
        # Key has not yet been created, this is mostly for QA since
        # some services may not be started
        if ($e =~ /no such key/) {
            await $redis_write->set(
                MONITOR_FAILURE_KEY_PREFIX . $stream => 1,
                EX                                   => MONITOR_FAILURE_TTL
            );
            $log->warnf("Stream $stream key has not yet been stored in the redis instance, the related service may not be running");
            return;
        }

        die "stream: $stream, error: $e";
    }

    for my $group ($redis_response->@*) {
        my $group_info = {$group->@*};
        my $group_name = $group_info->{name};

        my $tags = {tags => ['stream:' . $stream, 'group:' . $group_name]};

        # Connected workers
        stats_gauge($METRIC_PREFIX . 'workers.connected', $group_info->{'consumers'}, $tags);

        # Messages pending worker processing (either active, or attached to a worker that's stopped)
        stats_gauge($METRIC_PREFIX . 'messages.pending', $group_info->{'pending'}, $tags);

        # Stream metric calculation can be comparatively heavy, so we limit this to a single active
        # lookup - if the last iteration hasn't finished yet, leave it to run
        $active_stream_metrics{$stream}{$group_name} ||= stream_metrics($stream, $group_info)->on_ready(
            sub {
                delete $active_stream_metrics{$stream}{$group_name};
            });
    }
    return;
}

sub ping_redis {
    Future->wait_any(
        $redis->connected->then(
            sub {
                $redis->echo('LIVE')->on_done(
                    sub {
                        $log->info('Redis connection established.');
                        Future->done;
                    }
                )->on_fail(
                    sub {
                        Future->fail('Unable to send echo command to redis');
                    });
            }
        ),
        $loop->timeout_future(after => REDIS_CONNECTION_TIMEOUT))->get;
}

sub ping_circuit {
    my $backoff = Algorithm::Backoff->new(
        min => 2,
        max => 60,
    );

    while (1) {
        try {
            ping_redis();
            last;
        } catch ($e) {
            $log->errorf("Failed while pinging Redis server: %s", $e);
            die "\n" if $backoff->limit_reached;
            sleep $backoff->next_value;
        }
    }
}

ping_circuit();

$log->info($server . ' queue monitoring active');

Future->wait_any(
    map {
        (
            async sub {
                my ($code) = @_;
                while (1) {
                    try {
                        await $loop->delay_future(after => $interval_in_seconds);

                        await &fmap_void(
                            $code,
                            # Avoid piling too many requests into Redis at a time
                            concurrent => 8,
                            foreach    => [@$streams]);
                    } catch ($e) {
                        $log->errorf("An error occurred while monitoring Redis: %s", $e);
                        ping_circuit();
                    }
                }
            }
        )->($_)
    } (\&group_metrics,))->get;
