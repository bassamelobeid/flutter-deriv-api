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

has _cached_index => (
    is       => 'ro',
    init_arg => undef,
    default  => sub {
        +{map { $_ => score_for_channel_name($_) } shift->channels_from_keys};
    },
);

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

    my $sleep = $self->time_in_interval;
    $log->debugf('sleeping for %s secs...', $sleep);
    clock_nanosleep(CLOCK_REALTIME, $sleep * 1_000_000_000);

    return;
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
    # bid before price
    $score *= 101 if (($params->{price_daemon_cmd} // '') eq 'bid');
    # Real money accounts first
    $score *= 11 if ($params->{real_money});
    # Low total time is faster
    $score *= 7 if ($short_units->{$params->{duration_unit} // ''} and ($params->{duration} // 0) < 60);
    # Unvalidated is faster
    $score *= 2 if ($params->{skips_price_validation});

    return $score;
}

sub score_for_channel_name {
    my $item = shift;
    my ($params) = BOM::Pricing::v3::Utility::extract_from_channel_key($item);
    return score_for_parameters($params);
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

    # The bookkeeping overhead in maintaining a sorted array for the duration
    # seems like it would dominate doing a fresh sort on each invocation.
    # Also note that we might possibly price a contract for one extra interval
    my @channels = $self->channels_from_index;

    # Take note of keys that were not processed since the last pricing_interval
    # (which may be the same or not as $overflow, depending on how busy
    # the system gets)
    my $not_processed = $self->active_job_count;
    $log->debugf('got %s not processed: %s', $jobs_key, $not_processed) if $not_processed;

    $log->tracef('%s queue updating...', $jobs_key);
    $redis->del($jobs_key);
    $redis->lpush($jobs_key, @channels) if @channels;
    $log->debug($jobs_key . ' queue updated.');

    my $channel_count = 0 + @channels;

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
    my $cached  = $self->_cached_index;
    my $compare = {%$cached};
    for my $channel ($self->channels_from_keys) {
        my ($params) = BOM::Pricing::v3::Utility::extract_from_channel_key($channel);
        unless (exists $params->{barriers}) {    # exclude proposal_array
            my $relative_shortcode = BOM::Pricing::v3::Utility::create_relative_shortcode($params);
            $queued{$relative_shortcode}++;
        }
        # Now ensure our index is up-to-date and that everything gets processed
        if (not defined(delete $compare->{$channel}) and %$params) {
            # This is seemingly valid and new to the index:
            # Queue straightaway and add it to the index with its score
            $redis->lpush($jobs_key, $channel);
            $cached->{$channel} = score_for_parameters($params);
        }
    }
    $redis->hincrby('PRICE_METRICS::QUEUED', $_, $queued{$_}) for keys %queued;
    # Anything left in $compare no longer exists amongst the keys
    delete $cached->{$_} for keys %$compare;

    return undef;
}

sub active_job_count {
    my $self = shift;

    return $self->redis->llen($self->jobs_key) // 0;
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
    my $self     = shift;
    my %qi       = %{$self->_cached_index};
    my @channels = sort { $qi{$b} <=> $qi{$a} } (keys %qi);
    return @channels;
}

sub remove {
    my ($self, @items) = @_;

    my $count = 0;
    my $redis = $self->redis;
    for my $item (@items) {
        $count += 1 if (defined(delete $self->_cached_index->{$item}));
        $redis->del($item);
    }
    return $count;
}

sub add {
    my ($self, @items) = @_;

    my $count = 0;
    my $redis = $self->redis;
    for my $item (@items) {
        $self->_cached_index->{$item} = score_for_channel_name($item);
        $redis->set($item, 1);
        $count++;
    }

    return $count;
}

1;
