package BOM::Pricing::Queue;
use strict;
use warnings;
use feature 'state';
no indirect;

use Moo;

use DataDog::DogStatsd::Helper qw(stats_gauge stats_inc);
use Time::HiRes qw(clock_nanosleep clock_gettime CLOCK_REALTIME);
use LWP::Simple 'get';
use List::MoreUtils qw(natatime);
use List::UtilsBy qw(extract_by);
use JSON::MaybeUTF8 qw(:v1);
use Log::Any qw($log);
use Try::Tiny;
use YAML::XS;
use RedisDB;

use BOM::Config::RedisReplicated;
use BOM::Pricing::v3::Utility;

# Comments prepended with 'FUTURE:' note ways
# in which the queue-handling can/ought to be improved
# once a more modern version of Redis (>= 5.0.0) is
# available to these services

=head1 NAME

BOM::Pricing::Queue - manages the pricer queue.

=head1 DESCRIPTION

There are 2 modes:

=over 8

B<Normal:> every second will read up to 20k pricer keys and
add them to the pricer queue if the queue is empty. Otherwise
wait until the next second and try again.

=back

=cut

=head2 redis

Main redis client

=cut

has redis => (is => 'lazy');

=head2 internal_ip

IP address where are are running, used for logging

=cut

has internal_ip => (
    is      => 'ro',
    default => sub {
        get("http://169.254.169.254/latest/meta-data/local-ipv4") || '127.0.0.1';
    });

=head2 pricing_interval

Number of seconds for each pricing cycle. Defaults to 1 second, note that this isn't an integer - expect this to be 0.5 or 0.1 in future.

=cut

has pricing_interval => (
    is      => 'ro',
    default => sub { 1 },
);

=head2 reindex_queue_passes

Integer.  Number of passes between complete queue reindexing

Defaults to 43_189
A prime number of seconds close to 12h at a 1s pricing_interval

=cut

has reindex_queue_passes => (
    is      => 'ro',
    default => sub { 43_189 },
);

=head2 channels_key

String.  Key under which the pricing channels index
should be stored.

Defaults to 'pricer_channels'

=cut

has channels_key => (
    is      => 'ro',
    default => sub { 'pricer_channels' });

=head2 jobs_key

String.  Key into which the queue is to
push pricing jobs

Defaults to 'pricer_jobs'

=cut

has jobs_key => (
    is      => 'ro',
    default => sub { 'pricer_jobs' });

=head2 stat_tags

Tags for stats collection, defaults to ip

=cut

has stat_tags => (
    is      => 'ro',
    default => sub {
        my $self = shift;
        return +{tags => ['tag:' . $self->internal_ip]};
    });

sub _build_redis {
    return try {
        BOM::Config::RedisReplicated::redis_pricer();
    }
    catch {
        # delay a bit so that process managers like supervisord can
        # restart this processor gracefully in case of connection issues
        sleep(3);
        die 'Cannot connect to redis_pricer: ', $_;
    };
}

sub run {
    my $self = shift;

    $self->process() while 1;

    return 1;
}

sub process {
    my $self = shift;

    return $self->_process_price_queue();
}

=head2 _prep_for_next_interval

Used to sleep until the next pricing interval is reached

=cut

sub _prep_for_next_interval {
    my $self = shift;

    state $near_end = $self->pricing_interval / 4;
    my $sleep;

    until (defined $sleep) {
        my $rem = $self->time_in_interval;
        # If the time left is low, we immediately continue on.
        # Otherwise, examine the queue to see if items need sorting.
        # If nothing needed sorting, we will continue upon return.
        $sleep = ($rem <= $near_end) ? $rem : $self->clear_review_queue;
    }

    $log->debugf('sleeping for %s secs...', $sleep);
    clock_nanosleep(CLOCK_REALTIME, $sleep * 1_000_000_000);

    return;
}

=head2 clear_review_queue

Sort out recently added items for priority.

Returns true if there is no more work to be done, false
if we think we can still do something useful if called again.

=cut

sub clear_review_queue {
    my $self = shift;

    my $redis    = $self->redis;
    my $chan_key = $self->channels_key;
    # Grab an unscored item for processing
    my $item = ($redis->zrangebyscore($chan_key, 0, 0, 'LIMIT', 0, 1) // [])->[0];
    # All queue items reviewed, `_prep` may continue
    return $self->time_in_interval unless $item;
    my ($params) = BOM::Pricing::v3::Utility::extract_from_channel_key($item);
    if (%$params) {
        $redis->zadd($chan_key, score_for_parameters($params), $item);
        stats_inc('pricer_daemon.queue.item_reviewed', $self->stat_tags);
    } else {
        # If it didn't parse this time, there is no reason to believe it
        # will do so in the future
        $self->remove($item);
    }
    return undef;
}

sub score_for_parameters {
    my $params = shift;
    return 1 unless (ref($params) // '') eq 'HASH';
    # In the longer-term it may make sense to refactor any state vars
    # into config parameters.  First we need to figure out if this is
    # worth it and what the values ought to be
    state $short_units = {
        t => 1,
        s => 1,
    };
    # Indicate it has been touched, even if we make no further adjustments
    my $score = 1;
    $score *= 101 if (($params->{price_daemon_cmd} // '') eq 'bid');    # bid before price
    $score *= 11 if ($params->{real_money});                                                          # Real money accounts first
    $score *= 7  if ($short_units->{$params->{duration_unit} // ''} and $params->{duration} < 60);    # Low total time is faster
    $score *= 2  if ($params->{skips_price_validation});                                              # Unvalidated is faster

    return $score;
}

sub time_in_interval {
    my $self = shift;
    state $i = $self->pricing_interval;
    my $t = clock_gettime(CLOCK_REALTIME);
    return $i - ($t - (int($t / $i) * $i));
}

=head2 _process_price_queue

Processes the queue

=cut

sub _process_price_queue {
    my $self = shift;

    # Force reindex at startup
    state $passes_until_reindex = 0;

    $log->trace('processing price_queue...');
    $self->_prep_for_next_interval;
    my $redis    = $self->redis;
    my $overflow = $self->active_job_count;
    my $jobs_key = $self->jobs_key;

    # If we didn't manage to process everything within a single pricing_interval, we'll allow
    # one extra pricing_interval - this will cause price update rates to be halved on the UI.
    if ($overflow) {
        $log->debugf('Overflow of %d items on queue %s', $overflow, $jobs_key);
        $self->_prep_for_next_interval;
    }

    # We prepend short_code where possible, so sorting means we should get similar contracts together,
    # which should help with portfolio table update synchronisation
    my @channels = ($redis->exists($self->channels_key) and $passes_until_reindex--) ? $self->channels_from_index : $self->reindexed_channels;
    $passes_until_reindex ||= $self->reindex_queue_passes;
    # FUTURE: we should not spend time copying the keys back to the perl
    # process and then reloading them into redis.
    # The happy path is dropped.  The new-`if` (current-`else`) loads a missing
    # `$self->channels_key`.  After, we populate the queue:
    # $redis->zunionstore($self->jobs_key, 1, $self->channels_key)

    # Take note of keys that were not processed since the last second
    # (which may be the same or not as $overflow, depending on how busy
    # the system gets)
    my $not_processed = $self->active_job_count;
    $log->debugf('got %s not processed: %s', $jobs_key, $not_processed) if $not_processed;

    $log->tracef('%s queue updating...', $jobs_key);
    $redis->del($jobs_key);
    $redis->lpush($jobs_key, @channels) if @channels;
    # FUTURE: the code which accomplishes this (`@channels` stuff above) should instead
    # happen here. The `delete` happens for free on the `zunionstore` overwrite.
    $log->debug($jobs_key . ' queue updated.');

    my $channel_count = 0 + @channels;
    # FUTURE: we don't bring the keys back so we just count how many are in the
    # persistent queue:  `$redis->zcard($self->channels_key)`

    stats_gauge('pricer_daemon.queue.overflow',      $overflow,      $self->stat_tags);
    stats_gauge('pricer_daemon.queue.size',          $channel_count, $self->stat_tags);
    stats_gauge('pricer_daemon.queue.not_processed', $not_processed, $self->stat_tags);

    $log->trace('pricer_daemon_queue_stats updating...');
    $redis->set(
        'pricer_daemon_queue_stats',
        encode_json_utf8({
                overflow      => $overflow,
                not_processed => $not_processed,
                size          => $channel_count,
                updated       => Time::HiRes::time(),
            }));
    $log->debug('pricer_daemon_queue_stats updated.');

    # There might be multiple occurrences of the same 'relative shortcode'
    # to achieve higher performance, we count them first, then update the redis
    my %queued;
    for my $channel (@channels) {
        my ($params) = BOM::Pricing::v3::Utility::extract_from_channel_key($channel);
        unless (exists $params->{barriers}) {    # exclude proposal_array
            my $relative_shortcode = BOM::Pricing::v3::Utility::create_relative_shortcode($params);
            $queued{$relative_shortcode}++;
        }
    }
    $self->redis->hincrby('PRICE_METRICS::QUEUED', $_, $queued{$_}) for keys %queued;
    # FUTURE: This will need reconsideration/refactoring once we no longer
    # marshal the key-list into and out of perl.

    return undef;
}

sub active_job_count {
    my $self = shift;

    return $self->redis->llen($self->jobs_key);
    # FUTURE: This becomes `$redis->zcard($self->jobs_key)`
}

sub channels_from_keys {
    my $self = shift;

    return (
        sort @{
            $self->redis->scan_all(
                MATCH => 'PRICER_KEYS::*',
                COUNT => 20000
            ) // []});
}

sub channels_from_index {
    my $self = shift;
    return (@{$self->redis->zrevrangebyscore($self->channels_key, '+inf', 0) // []});
}

sub reindexed_channels {
    my $self  = shift;
    my $redis = $self->redis;
    # Clear up old work in case it has gotten out of sync
    $redis->del($self->channels_key);
    # Convert the extant channels into the queue
    my @channels = $self->channels_from_keys;
    $self->add(@channels);
    return @channels;
}

sub remove {
    my ($self, @items) = @_;

    my $redis = $self->redis;

    $redis->zrem($self->channels_key, @items);
    return $redis->del(@items);
}

sub add {
    my ($self, @items) = @_;

    my $redis    = $self->redis;
    my $chan_key = $self->channels_key;

    my $count = 0;
    foreach my $item (@items) {
        $count += $redis->zadd($chan_key, 0, $item);
        $redis->set($item, 1);
    }

    return $count;
}

1;
