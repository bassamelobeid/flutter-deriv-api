package BOM::Pricing::Queue;
use strict;
use warnings;
use feature 'state';
no indirect;

use Moo;

use DataDog::DogStatsd::Helper qw(stats_gauge stats_inc);
use Time::HiRes qw(clock_nanosleep CLOCK_REALTIME);
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

B<Priority:> subscribes to the high priority price channel and adds
items to the high priority pricer queue as they are received.

=back

=cut

=head2 redis

Main redis client

=cut

has redis => (is => 'lazy');

=head2 redis_priority

Secondary redis client, only used in priority mode

=cut

has redis_priority => (is => 'lazy');

=head2 internal_ip

IP address where are are running, used for logging

=cut

has internal_ip => (
    is      => 'ro',
    default => sub {
        get("http://169.254.169.254/latest/meta-data/local-ipv4") || '127.0.0.1';
    });

=head2 priority

Priority mode, boolean

=cut

has priority => (
    is       => 'ro',
    required => 1
);

=head2 pricing_interval

How often for each pricing queueing, in seconds, default 1

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

=head2 stat_tags

Tags for stats collection, defaults to ip

=cut

has stat_tags => (
    is      => 'ro',
    default => sub {
        my $self = shift;
        return +{tags => ['tag:' . $self->internal_ip]};
    });

sub BUILD {
    my $self = shift;

    $self->_subscribe_priority_queue() if $self->priority;

    return undef;
}

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

# second redis client used for priority queue subscription
sub _build_redis_priority {
    return try {
        my %config = YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml')->{write}->%*;
        return RedisDB->new(%config);
    }
    catch {
        sleep(3);
        die 'Cannot connect to redis_pricer for priority queue: ', $_;
    };
}

sub run {
    my $self = shift;

    $self->process() while 1;

    return 1;
}

sub process {
    my $self = shift;

    return $self->priority ? $self->_process_priority_queue() : $self->_process_price_queue();
}

=head2 _prep_for_next_interval

Used to sleep until the next pricing interval is reached

=cut

sub _prep_for_next_interval {
    my $self = shift;
    my $i    = $self->pricing_interval;
    my ($t, $sleep, $continue);
    until ($continue) {
        $t = Time::HiRes::time();
        $sleep = $i - ($t - (int($t / $i) * $i));
        # If the time left is low, we immediately continue on.
        # Otherwise, examine the queue to see if items need sorting.
        # If nothing needed sorting, we will continue upon return.
        $continue = ($sleep <= $i / 4) ? 1 : $self->_examine_queue;
    }

    $log->debugf('sleeping at %s for %s secs...', $t, $sleep);
    clock_nanosleep(CLOCK_REALTIME, $sleep * 1_000_000_000);

    return undef;
}

my $chan_key = 'pricer_channels';
my $jobs_key = 'pricer_jobs';

=head2 _examine_queue

Sort out recently added items for priority

=cut

sub _examine_queue {
    my $self = shift;

    my $redis = $self->redis;
    # Grab an unscored item for processing
    my $item = @{$redis->zrangebyscore($chan_key, 0, 0, 'LIMIT', 0, 1) // []}[0];
    # All queue items reviewed, `_prep` may continue
    return 1 unless $item;
    my %params = eval {
        my $ic = $item;
        $ic =~ s/^PRICER_KEYS:://;
        @{decode_json_utf8($ic) // []};
    };
    if (not %params) {
        # If it didn't parse this time, there is no reason to believe it
        # will do so in the future
        $redis->zrem($chan_key, $item);
        $redis->del($item);
        return;
    }
    # Indicate it has been touched, even if we make no further adjustments
    my $score = 1;
    $score *= 101 if ($params{real_money});      # Real money accounts first
    $score *= 13  if (not $params{proposal});    # Extant contracts get priority
    state $short_units = {
        t => 1,
        s => 1,
    };
    # In the longer-term it may make sense to refactor any state vars
    # into config parameters.  First we need to figure out if this is
    # worth it and what the values ought to be
    $score *= 7 if ($short_units->{$params{duration_unit} // ''} and $params{duration} < 60);    # Low total time is faster
    $score *= 2 if ($params{skips_price_validation});                                            # Unvalidated is faster
    $redis->zadd($chan_key, $score, $item);
    stats_inc('pricer_daemon.queue.item_reviewed', $self->stat_tags);
    return;
}

=head2 _process_price_queue

Processes the normal priority queue

=cut

# Force reindex at startup
my $passes_until_reindex = 0;

sub _process_price_queue {
    my $self = shift;

    $log->trace('processing price_queue...');
    $self->_prep_for_next_interval;
    my $redis    = $self->redis;
    my $overflow = $redis->llen($jobs_key);
    # FUTURE: This becomes `$redis->zcard($jobs_key)`

    # If we didn't manage to process everything within a single pricing_interval, we'll allow
    # one extra pricing_interval - this will cause price update rates to be halved on the UI.
    if ($overflow) {
        $log->debugf('got ' . $jobs_key . ' overflow: %s', $overflow);
        $self->_prep_for_next_interval;
    }

    # We prepend short_code where possible, so sorting means we should get similar contracts together,
    # which should help with portfolio table update synchronisation
    my @keys;
    # FUTURE: we should not spend time copying the keys back to the perl
    # process and then reloading them into redis.
    # The happy path is dropped.  The new-`if` (current-`else`) loads a missing
    # `$chan_key`.  After, we populate the queue:
    # $redis->zunionstore($jobs_key, 1, $chan_key)
    if ($redis->exists($chan_key) and $passes_until_reindex--) {
        # Happy path, use the extant queue
        # order from high priority to low
        # We use the scores here so that we can potentially be selective later
        @keys = @{$redis->zrevrangebyscore($chan_key, '+inf', 0) // []};
    } else {
        # Clear up old work in case it has gotten out of sync
        $redis->del($chan_key);
        $passes_until_reindex = $self->reindex_queue_passes;
        # Convert the extant channels into the queue
        @keys = sort @{
            $redis->scan_all(
                MATCH => 'PRICER_KEYS::*',
                COUNT => 20000
            ) // []};
        # Ensure we don't have a too long command...
        # at the cost of extra roundtrips
        my $iter = natatime 128, @keys;
        while (my @actives = map { (0, $_) } ($iter->())) {
            $redis->zadd($chan_key, @actives);
        }
    }

    # Take note of keys that were not processed since the last second
    # (which may be the same or not as $overflow, depending on how busy
    # the system gets)
    my $not_processed = $redis->llen($jobs_key);
    # FUTURE: This becomes a ZCARD call as well: `$redis->zcard($jobs_key)`
    $log->debugf('got ' . $jobs_key . ' not processed: %s', $not_processed) if $not_processed;

    $log->trace($jobs_key . ' queue updating...');
    $redis->del($jobs_key);
    $redis->lpush($jobs_key, @keys) if @keys;
    # FUTURE: the code which accomplishes this (`@keys` stuff above) should instead
    # happen here. The `delete` happens for free on the `zunionstore` overwrite.
    $log->debug($jobs_key . ' queue updated.');

    my $key_count = 0 + @keys;
    # FUTURE: we don't bring the keys back so we just count how many are in the
    # persistent queue:  `$redis->zcard($chan_key)`

    stats_gauge('pricer_daemon.queue.overflow',      $overflow,      $self->stat_tags);
    stats_gauge('pricer_daemon.queue.size',          $key_count,     $self->stat_tags);
    stats_gauge('pricer_daemon.queue.not_processed', $not_processed, $self->stat_tags);

    $log->trace('pricer_daemon_queue_stats updating...');
    $redis->set(
        'pricer_daemon_queue_stats',
        encode_json_utf8({
                overflow      => $overflow,
                not_processed => $not_processed,
                size          => $key_count,
                updated       => Time::HiRes::time(),
            }));
    $log->debug('pricer_daemon_queue_stats updated.');

    # There might be multiple occurrences of the same 'relative shortcode'
    # to achieve higher performance, we count them first, then update the redis
    my %queued;
    for my $key (@keys) {
        my $params = {decode_json_utf8($key =~ s/^PRICER_KEYS:://r)->@*};
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

=head2 _subscribe_priority_queue

Subscribes to the high priority price channel and sets the handler sub

=cut

sub _subscribe_priority_queue {
    my $self = shift;

    $log->trace('subscribing to high_priority_prices channel...');
    $self->redis_priority->subscribe(
        high_priority_prices => sub {
            my (undef, $channel, $pattern, $message) = @_;
            stats_inc('pricer_daemon.priority_queue.recv', $self->stat_tags);
            $log->debug('received message, updating pricer_jobs_priority: ', {message => $message});
            $self->redis->lpush('pricer_jobs_priority', $message);
            $log->debug('pricer_jobs_priority updated.');
            stats_inc('pricer_daemon.priority_queue.send', $self->stat_tags);
        });

    return undef;
}

=head2 _process_priority_queue

Blocks until a message arrives on the high priority price channel

=cut

sub _process_priority_queue {
    my $self = shift;

    $log->trace('processing priority price_queue...');
    try {
        $self->redis_priority->get_reply();
    }
    catch {
        $log->warnf("Caught error on priority queue subscription: %s", $_);
        # resubscribe if our $redis handle timed out
        $self->_subscribe_priority_queue() if /not waiting for reply/;
    };

    return undef;
}

1;
