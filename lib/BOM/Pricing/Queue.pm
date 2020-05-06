package BOM::Pricing::Queue;

use strict;
use warnings;

use parent qw(IO::Async::Notifier);

use utf8;
use mro;
no indirect;

use DataDog::DogStatsd::Helper qw(stats_gauge stats_inc);
use LWP::Simple 'get';
use List::UtilsBy qw(extract_by);
use JSON::MaybeUTF8 qw(:v1);
use Syntax::Keyword::Try;
use Future::AsyncAwait;
use Net::Async::Redis;

use Log::Any qw($log);

use BOM::Config::Redis;
use BOM::Pricing::v3::Utility;

=encoding utf-8

=head1 NAME

BOM::Pricing::Queue - manages the pricer queue.

=head1 DESCRIPTION

Wakes up every pricing interval - currently defined as 1 second -
and copies pricer keys into the queue of work for the pricer dæmons
to process.

=cut

# Number of keys to attempt to retrieve for each SCAN iteration
use constant DEFAULT_KEYS_PER_BATCH => 1000;

# Process this many entries for metrics before checking
# whether we've run out of time. Only used when metric
# recording is enabled.
use constant KEYS_PER_METRICS_ITERATION => 100;

=head2 pricing_interval

Interval between pricing queue population steps, in seconds.

Defaults to 1.

=cut

sub pricing_interval { shift->{pricing_interval} //= 1.0 }

=head2 redis_instance

Establish a connection to a new Redis instance.

Returns a L<Net::Async::Redis> instance.

=cut

sub redis_instance {
    my ($self) = @_;
    try {
        my $cfg = BOM::Config::redis_pricer_config()
            or die 'no config found for Redis pricers';
        my $redis_cfg = $cfg->{write}
            or die 'pricer write config not found in BOM::Config';
        $self->add_child(
            my $redis = Net::Async::Redis->new(
                host => $redis_cfg->{host},
                port => $redis_cfg->{port},
                (
                    $redis_cfg->{password}
                    ? (auth => $redis_cfg->{password})
                    : ()
                ),
            ));
        return $redis;
    }
    catch {
        my $e = $@;
        # delay a bit so that process managers like supervisord can
        # restart this processor gracefully in case of connection issues
        sleep(3);
        die 'Cannot connect to redis_pricer: ', $e;
    }
}

=head2 redis

Main redis client.

=cut

sub redis {
    my ($self) = @_;
    return $self->{redis} //= $self->redis_instance;
}

=head2 metrics_redis

Secondary Redis client for metrics.

=cut

sub metrics_redis {
    my ($self) = @_;
    return $self->{metrics_redis} //= $self->redis_instance;
}

=head2 internal_ip

IP address where we are running, used for logging.

=cut

sub internal_ip {
    my ($self) = @_;
    $self->{internal_ip} //= do {
        get("http://169.254.169.254/latest/meta-data/local-ipv4") || '127.0.0.1';
    };
}

=head2 record_price_metrics

Flag to enable or disable recording of pricing metrics.

=cut

sub record_price_metrics { shift->{record_price_metrics} }

=head2 run

Main loop. Triggered automatically when this instance is added to an event loop.

=cut

async sub run {
    my $self = shift;

    await $self->process while 1;

    return 1;
}

=head2 configure

Applies settings.

=over 4

=item * C<internal_ip> - the IP address to report in statsd

=item * C<record_price_metrics> - controls whether or not we should attempt to write
price metrics, this is optional since there is a performance impact

=item * C<keys_per_batch> - number of keys to pull from Redis for each SCAN iteration, higher values are more efficient, lower reduce latency between start of pricing interval and having work for the pricer dæmons to pick up

=back

=cut

sub configure {
    my ($self, %args) = @_;
    for my $k (qw(internal_ip record_price_metrics keys_per_batch pricing_interval)) {
        $self->{$k} = delete $args{$k} if exists $args{$k};
    }
    return $self->next::method(%args);
}

sub keys_per_batch { shift->{keys_per_batch} //= DEFAULT_KEYS_PER_BATCH }

=head2 next_interval



=cut

sub next_interval {
    my ($self, $t) = @_;
    die 'need to pass time' unless $t;
    my $scaled = int($t / $self->pricing_interval);
    my $next = $self->pricing_interval * ($scaled + 1);
    return $next;
}

=head2 next_tick

Used to sleep until the next pricing interval should start, as
defined by L</pricing_interval>.

Returns a L<Future> which will resolve once the time has elapsed.

=cut

async sub next_tick {
    my ($self) = @_;
    my $t      = Time::HiRes::time();
    my $next   = $self->next_interval($t);
    my $sleep  = $next - $t;
    $log->debugf('sleeping at %.3f for %.2f ms...', $t, 1000.0 * $sleep);
    await $self->loop->delay_future(at => $next);
    my $now = Time::HiRes::time();
    $log->tracef('Actual sleep time was %.2f ms', 1000.0 * ($now - $t));
    return $sleep;
}

=head2 submit_jobs

Takes the following parameters:

=over 4

=item * C<$keys> - an arrayref of pricing keys to push to the queues

=back

Returns a L<Future> which will resolve once the batches are submitted.

=cut

async sub submit_jobs {
    my ($self, $keys) = @_;

    # Two key points to note here:
    # - we extract 'bids' on the next line, and that's a destructive
    # process, so we copy out the 'asks' first.
    # - we prepend short_code where possible, so sorting means we should
    # get similar contracts together, which we expect to help with
    # portfolio table update synchronisation: looks odd if identical
    # contracts are updating at different rates
    my @asks = sort $keys->@*;

    # Note that we avoid decoding JSON here for faster results;
    # the pricer dæmon workers will flag any failures later
    my @bids = extract_by { /"price_daemon_cmd","bid"/ } @asks;

    # Prioritise bids if we had any, assumes pricer dæmon uses `rpop`
    await $self->redis->lpush('pricer_jobs', @bids) if @bids;
    await $self->redis->lpush('pricer_jobs', @asks) if @asks;
    $log->debug('pricer_jobs queue updated.');
}

=head2 process

Processes the next iteration of the queue.

=cut

async sub process {
    my $self = shift;

    $log->trace('processing price_queue...');
    await $self->next_tick();
    my $start = Time::HiRes::time();

    # Take note of keys that were not processed since the last pricing interval
    my $overflow = await $self->redis->llen('pricer_jobs');
    stats_gauge('pricer_daemon.queue.overflow', $overflow, {tags => ['tag:' . $self->internal_ip]});
    if ($overflow) {
        $log->debugf('got pricer_jobs overflow: %d', $overflow);
    }

    # We now loop through whatever PRICER_KEYS::* entries we have
    # in Redis, doing these in batches: might be a lot of keys,
    # so those batches are grouped.
    my @all_keys;
    my $cursor = 0;
    my $deleted;
    KEY_BATCH:
    do {
        my $details = await $self->redis->scan(
            $cursor,
            match => 'PRICER_KEYS::*',
            count => $self->keys_per_batch,
        );
        ($cursor, my $keys) = $details->@*;

        # Track these for metrics processing later
        push @all_keys, $keys->@*;

        # Defer the delete until after we have the first batch
        # of keys - might as well give pricers as much opportunity
        # to finish up as possible
        await $self->redis->del('pricer_jobs') unless $deleted++;

        await $self->submit_jobs($keys);

        # We may have a *lot* of keys, and the processing time here
        # could vary significantly. We can't assume that we get through
        # the full list within the allotted time, nice though that would
        # be, so we check for that here.
        my $now = Time::HiRes::time();
        if (($now - $start) > 0.8 * $self->pricing_interval) {
            $log->errorf('Too many keys, we have used 80% of the pricing interval so we are bailing out');
            last KEY_BATCH;
        }
    } while $cursor;

    $log->trace('pricer_jobs queue updating...');

    stats_gauge('pricer_daemon.queue.size', 0 + @all_keys, {tags => ['tag:' . $self->internal_ip]});

    # It's not essential to have every iteration recorded, so if
    # the previous update is still running then we would skip this
    $self->{queue_stats} //= do {
        $log->trace('pricer_daemon_queue_stats updating...');
        $self->metrics_redis->set(
            'pricer_daemon_queue_stats',
            encode_json_utf8({
                    overflow => $overflow,
                    size     => 0 + @all_keys,
                    updated  => Time::HiRes::time(),
                })
            )->on_ready(
            sub {
                delete $self->{queue_stats};
                $log->debug('pricer_daemon_queue_stats updated.');
            });
    };

    # Likewise with metrics, we'll trigger the action but let
    # it run in the background as a lower priority; if we're
    # still processing metrics from the last iteration, then
    # we'll skip this one.
    unless ($self->{send_stats}) {
        # Unfortunately we can't use //= here, because Perl
        # thinks that the returned value is being discarded
        # and warns about a useless assignment to temporary
        $self->{send_stats} = $self->send_stats(\@all_keys)->on_ready(
            sub {
                delete $self->{send_stats};
            });
    }

    my $now = Time::HiRes::time();
    stats_gauge('pricer_daemon.queue.time', 1000.0 * ($now - $start), {tags => ['tag:' . $self->internal_ip]});
    return undef;
}

=head2 send_stats

If L</record_price_metrics> is set, will attempt to analyse
the pricing keys from this iteration and generate some metrics.
Returns immediately if this is not enabled.

Takes the following parameters:

=over 4

=item * C<$keys> - arrayref of pricer keys we received

=back

Returns a L<Future> which will resolve once metrics have been recorded.

=cut

async sub send_stats {
    my ($self, $keys) = @_;
    return unless $self->record_price_metrics;

    my $interval_fraction = 0.8;

    my $start = Time::HiRes::time();

    # There might be multiple occurrences of the same 'relative shortcode'
    # to achieve higher performance, we count them first, then update the redis
    my %queued;
    my $count = 0;
    METRIC:
    for my $key ($keys->@*) {
        unless ($count++ % KEYS_PER_METRICS_ITERATION) {
            my $completion = (Time::HiRes::time() - $start) / $self->pricing_interval;
            if ($completion >= $interval_fraction) {
                $log->warnf('Too many keys to process all metrics, have reached %d%% of the pricing interval', 100.0 * $completion);
                last METRIC;
            }
        }

        my %params = decode_json_utf8($key =~ s/^PRICER_KEYS:://r)->@*;
        # Exclude proposal_array
        next if exists $params{barriers};

        if ($params{contract_id} and $params{landing_company}) {
            my $contract_params = BOM::Pricing::v3::Utility::get_contract_params(@params{qw(contract_id landing_company)});
            @params{keys %$contract_params} = values %$contract_params;
        }

        my $relative_shortcode = BOM::Pricing::v3::Utility::create_relative_shortcode(\%params);
        $queued{$relative_shortcode}++;
    }

    await Future->needs_all(    #
        map {                   #
            $self->redis->hincrby('PRICE_METRICS::QUEUED', $_, $queued{$_})
            } sort keys %queued    #
    );
}

1;
