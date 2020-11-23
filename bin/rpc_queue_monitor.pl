#!/usr/bin/env perl 
use strict;
use warnings;

use DataDog::DogStatsd::Helper qw(stats_timing stats_gauge);
use Future::Utils qw(fmap_void);
use List::Util qw(min);
use IO::Async::Loop;
use Net::Async::Redis;
use Future::AsyncAwait;
use Log::Any qw($log);
use Log::Any::Adapter qw(Stdout), log_level => 'info';
use Getopt::Long;
use BOM::Config::Redis;

=head1 NAME rpc_queue_monitor.pl

RPC Queue monitoring script.

=head1 SYNOPSIS

    perl rpc_queue_monitor.pl [--redis redis://...]  [--stream general] [--stream multiple_stream...]
    
=cut

use constant DD_METRIC_PREFIX         => 'bom_rpc.v_3.monitoring.';
use constant XRANGE_BATCH_LIMIT       => 200;
use constant REDIS_CONNECTION_TIMEOUT => 5;

my $redis_config = BOM::Config::Redis::redis_config('rpc', 'read');

GetOptions(
    'stream|s=s@'  => \(my $streams             = ['general']),
    'redis|r=s'    => \(my $redis_uri           = $redis_config->{uri}),
    'interval|i=i' => \(my $interval_in_seconds = 30),
) or die("Error in input arguments\n");

my $loop = IO::Async::Loop->new;
$loop->add(my $redis = Net::Async::Redis->new(uri => $redis_uri));

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

    my $oldest     = $group_info->{'last-delivered-id'};
    my $group_name = $group_info->{'name'};

    ($redis_response) = await $redis->xpending($stream, $group_name);
    my ($count, $first_id) = @$redis_response;
    $oldest = $first_id if defined($first_id) and compare_id($oldest, $first_id) > 0;

    my $total = 0;
    if ($oldest and $oldest ne '0-0' and compare_id($oldest, $info{'first-entry'}[0]) > 0) {

        my ($direction, $endpoint, $limit) = ('xrange', '-', XRANGE_BATCH_LIMIT);
        {
            no warnings 'numeric';
            # We want to process as few items as possible, so we start at the closest end,
            # with the assumption that the items are evenly distributed
            # Data format is xxx-yyy, we really only care about the timestamp information
            # which is in epoch milliseconds as the xxx value
            if ($oldest - $info{'first-entry'}[0] > $info{'last-entry'}[0] - $oldest) {
                $direction = 'xrevrange';
                $endpoint  = '+';
            }
        }

        while (1) {
            my ($redis_response) = await $redis->$direction($stream, $endpoint, $oldest, COUNT => $limit);
            $total += @$redis_response;
            last unless @$redis_response >= $limit;
            # Overlapping ranges, so the next ID will be included twice
            --$total;
            $endpoint = $redis_response->[-1][0];
            await $loop->delay_future(after => 0.1);
        }
        $total = $info{length} - $total if $direction eq 'xrange';
    }

    stats_gauge(DD_METRIC_PREFIX . 'queue.size', $total, {tags => ['stream:' . $stream]});

    return;
}

# Tracking active stream_metrics queries - 2-level hash containing stream and group
my %active_stream_metrics;

async sub group_metrics {
    my ($stream) = @_;

    my ($redis_response) = await $redis->xinfo(GROUPS => $stream);

    for my $group ($redis_response->@*) {
        my $group_info = {$group->@*};
        my $group_name = $group_info->{name};

        my $tags = {tags => ['stream:' . $stream, 'group:' . $group_name]};

        # Queue latency
        my ($timestamp) = $group_info->{'last-delivered-id'} =~ /([0-9]+)-/;
        $timestamp /= 1000.0;
        my $elapsed = $loop->time - $timestamp;
        stats_timing(DD_METRIC_PREFIX . 'delivery.latency', $elapsed * 1000.0, $tags);

        # Connected workers
        stats_gauge(DD_METRIC_PREFIX . 'workers.connected', $group_info->{'consumers'}, $tags);

        # Messages pending worker processing (either active, or attached to a worker that's stopped)
        stats_gauge(DD_METRIC_PREFIX . 'messages.pending', $group_info->{'pending'}, $tags);

        # Stream metric calculation can be comparatively heavy, so we limit this to a single active
        # lookup - if the last iteration hasn't finished yet, leave it to run
        $active_stream_metrics{$stream}{$group_name} ||= stream_metrics($stream, $group_info)->on_ready(
            sub {
                delete $active_stream_metrics{$stream}{$group_name};
            });
    }
    return;
}

Future->needs_any(
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
    $loop->delay_future(after => REDIS_CONNECTION_TIMEOUT)->then(
        sub {
            die('Connection to redis could not be established');
        }))->get;

$log->info('RPC queue monitoring active');

Future->wait_any(
    map { (
            async sub {
                my ($code) = @_;
                while (1) {
                    await &fmap_void(
                        $code,
                        # Avoid piling too many requests into Redis at a time
                        concurrent => 8,
                        foreach    => [@$streams]);

                    await $loop->delay_future(after => $interval_in_seconds);
                }
            }
        )->($_)
    } (\&group_metrics,))->get;
