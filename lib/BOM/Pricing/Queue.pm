package BOM::Pricing::Queue;
use strict;
use warnings;
no indirect;

use Moo;

use DataDog::DogStatsd::Helper qw(stats_gauge stats_inc);
use Time::HiRes qw(clock_nanosleep CLOCK_REALTIME);
use LWP::Simple 'get';
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

=head2 _sleep_to_next_second

Used to sleep until the next clock second is reached

=cut

sub _sleep_to_next_second {
    my $t = Time::HiRes::time();
    my $sleep = 1 - ($t - int($t));
    $log->debugf('sleeping at %s for %s secs...', $t, $sleep);
    clock_nanosleep(CLOCK_REALTIME, $sleep * 1_000_000_000);

    return undef;
}

=head2 _process_price_queue

Processes the normal priority queue

=cut

sub _process_price_queue {
    my $self = shift;

    $log->trace('processing price_queue...');
    _sleep_to_next_second();
    my $overflow = $self->redis->llen('pricer_jobs');

    # If we didn't manage to process everything within 1s, we'll allow 1s extra - this will cause price update rates to
    # be halved on the UI.
    if ($overflow) {
        $log->debugf('got pricer_jobs overflow: %s', $overflow);
        _sleep_to_next_second();
    }

    # We prepend short_code where possible, so sorting means we should get similar contracts together,
    # which should help with portfolio table update synchronisation
    my @keys = sort @{
        $self->redis->scan_all(
            MATCH => 'PRICER_KEYS::*',
            COUNT => 20000
        )};

    # Take note of keys that were not processed since the last second
    # (which may be the same or not as $overflow, depending on how busy
    # the system gets)
    my $not_processed = $self->redis->llen('pricer_jobs');
    $log->debugf('got pricer_jobs not processed: %s', $not_processed) if $not_processed;

    $log->trace('pricer_jobs queue updating...');
    $self->redis->del('pricer_jobs');
    $self->redis->lpush('pricer_jobs', @keys) if @keys;
    $log->debug('pricer_jobs queue updated.');

    stats_gauge('pricer_daemon.queue.overflow',      $overflow,      {tags => ['tag:' . $self->internal_ip]});
    stats_gauge('pricer_daemon.queue.size',          0 + @keys,      {tags => ['tag:' . $self->internal_ip]});
    stats_gauge('pricer_daemon.queue.not_processed', $not_processed, {tags => ['tag:' . $self->internal_ip]});

    $log->trace('pricer_daemon_queue_stats updating...');
    $self->redis->set(
        'pricer_daemon_queue_stats',
        encode_json_utf8({
                overflow      => $overflow,
                not_processed => $not_processed,
                size          => 0 + @keys,
                updated       => Time::HiRes::time(),
            }));
    $log->debug('pricer_daemon_queue_stats updated.');

    # There might be multiple occurrences of the same 'relative shortcode'
    # to achieve higher performance, we count them first, then update the redis
    my %queued;
    for my $key (@keys) {
        my $params = {decode_json_utf8($key =~ s/^PRICER_KEYS:://r)->@*};
        if ($params->{contract_id} and $params->{landing_company}) {
            my $contract_params = BOM::Pricing::v3::Utility::get_contract_params($self->redis, $params->{contract_id}, $params->{landing_company});
            $params = {%$params, %$contract_params};
        }
        unless (exists $params->{barriers}) {    # exclude proposal_array
            my $relative_shortcode = BOM::Pricing::v3::Utility::create_relative_shortcode($params);
            $queued{$relative_shortcode}++;
        }
    }
    $self->redis->hincrby('PRICE_METRICS::QUEUED', $_, $queued{$_}) for keys %queued;

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
            stats_inc('pricer_daemon.priority_queue.recv', {tags => ['tag:' . $self->internal_ip]});
            $log->debug('received message, updating pricer_jobs_priority: ', {message => $message});
            $self->redis->lpush('pricer_jobs_priority', $message);
            $log->debug('pricer_jobs_priority updated.');
            stats_inc('pricer_daemon.priority_queue.send', {tags => ['tag:' . $self->internal_ip]});
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
