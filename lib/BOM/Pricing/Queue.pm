package BOM::Pricing::Queue;

use strict;
use warnings;

use parent qw(IO::Async::Notifier);

use utf8;
use mro;
no indirect;

use DataDog::DogStatsd::Helper qw(stats_gauge stats_inc stats_timing);
use LWP::Simple 'get';
use JSON::MaybeUTF8 qw(:v1);
use Syntax::Keyword::Try;
use Future::AsyncAwait;
use Future::Utils qw(fmap0);
use Net::Async::Redis;

use Log::Any qw($log);

use BOM::Config::Redis;
use BOM::Pricing::v3::Utility;
use Finance::Contract::Longcode qw(shortcode_to_parameters);

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

=head2 redis_instance

Establish a connection to a new Redis instance.

Returns a L<Net::Async::Redis> instance.

=cut

sub redis_instance {
    my ($self, %args) = @_;
    try {
        my $cfg = $args{config} // BOM::Config::redis_pricer_config()
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
    } catch ($e) {
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

=head2 contract_redis

Returns a L<Net::Async::Redis> instance for accessing
open contract data.

=cut

sub contract_redis {
    my ($self) = @_;
    return $self->{contract_redis} //= $self->redis_instance(config => BOM::Config::redis_pricer_shared_config());
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

=head2 connect_to_feed

connects to master read feed redis and returns the redis object

=cut

sub connect_to_feed {
    my ($self) = @_;
    my $cfg    = BOM::Config::redis_feed_config()->{"master-read"};
    my $redis  = Net::Async::Redis->new(
        host => $cfg->{host},
        port => $cfg->{port},
        auth => $cfg->{password},
    );
    if (Net::Async::Redis->VERSION < "3.023") {
        # I tried to find a solution without resorting to monkey patching, but
        # couldn't find anything that would work for all the cases. We need to
        # detect when we were disconnected.Upgrading to 3.023 is in the
        # pipeline, but it causes tests in multiple packages to fail and I
        # can't even estimate the time that would be required to fix them all.
        no warnings 'redefine';    ## no critic
        *Net::Async::Redis::Subscription::cancel = sub {
            my ($self) = @_;
            my $f = $self->events->completed;
            $self->events->fail('cancelled') unless $f->is_ready;
            $self;
        };
    }
    $self->add_child($redis);
    return $redis;
}

=head2 run

Main loop. Triggered automatically when this instance is added to an event loop.

=cut

async sub run {
    my $self       = shift;
    my $feed_redis = $self->connect_to_feed;

    my @futures = (
        $self->run_contract_updater,

        # queue proposals for pricing when tick updates
        $feed_redis->connect->then(
            sub {
                $feed_redis->psubscribe('TICK_ENGINE::*');
            }
        )->then(
            sub {
                my ($sub) = @_;
                my $payload_source = $sub->events->map('payload')->decode('UTF-8')->decode('json');
                $payload_source->each(
                    sub {
                        my ($tick) = @_;
                        my $ptick = {
                            underlying => $tick->{symbol},
                            epoch      => $tick->{epoch},
                            quote      => $tick->{quote},
                            received   => Time::HiRes::time(),
                        };
                        stats_timing(
                            'pricer_daemon.queue.tick_receive_latency',
                            1000 * ($ptick->{received} - $ptick->{epoch}),
                            {tags => ['tag:' . $self->internal_ip, 'symbol:' . $tick->{symbol}]});
                        $self->process($tick->{symbol}, $ptick)->retain;
                    });
                return $payload_source->completed->on_fail(
                    sub {
                        my $error = shift;
                        $log->errorf("processing pricing queue failed with: %s", $error);
                    });
            }
        ),

        $self->submit_unknown,

        $self->submit_noticks,

        # update datadog stats every second and manage queue size
        $self->run_stats,

        $self->keep_poc_alive,
    );

    my $future = Future->wait_any(@futures);

    return $future->get;
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
    for my $k (qw(internal_ip record_price_metrics keys_per_batch)) {
        $self->{$k} = delete $args{$k} if exists $args{$k};
    }
    return $self->next::method(%args);
}

sub keys_per_batch { shift->{keys_per_batch} //= DEFAULT_KEYS_PER_BATCH }

=head2 submit_jobs

Takes the following parameters:

=over 4

=item * C<$keys> - an arrayref of pricing keys to push to the queues

=back

Returns a L<Future> which will resolve once the batches are submitted.

=cut

async sub submit_jobs {
    my ($self, $contracts, $tick) = @_;

    my @accus;
    my @asks;
    my @bids;
    my $tick_json = $tick ? "::" . encode_json_utf8($tick) : "";
    for my $contract (@$contracts) {
        if (index($contract, q("contract_type","ACCU")) > 0) {
            push @accus, $contract . $tick_json;
        } elsif (index($contract, q("price_daemon_cmd","bid")) > 0) {
            push @bids, $contract . $tick_json;
        } else {
            push @asks, $contract . $tick_json;
        }
    }

    # accumulator contracts must be priced with minimum latency, so we push them into a priority queue
    if (@accus) {
        await $self->redis->lpush('pricer_jobs_p0', @accus);
        $self->{stats}{queued_p0} += @accus;
    }
    # Prioritise bids if we had any, assumes pricer dæmon uses `rpop`
    await $self->redis->lpush('pricer_jobs', @bids) if @bids;
    await $self->redis->lpush('pricer_jobs', @asks) if @asks;
    if ($tick and $tick->{received}) {
        stats_timing('pricer_daemon.queue.tick_submit_latency', 1000 * (Time::HiRes::time() - $tick->{received}));
    }
    $log->debug('pricer_jobs queue updated.');
}

=head2 run_stats

creates a timer that runs stats update every 60 sec

=cut

async sub run_stats {
    my $self = shift;
    while (1) {
        await $self->loop->delay_future(at => int($self->loop->time) + 1);
        await $self->stats;
    }
}

=head2 stats

Updates stats in data dog and in redis. Also dequeues jobs that were not
processed since the last run.

=cut

async sub stats {
    my $self = shift;

    my $now   = Time::HiRes::time();
    my $stats = $self->{stats};
    $self->{stats} = {
        start_time => $now,
        queued     => 0,
        queued_p0  => 0,
        proc_time  => 0,
    };
    return unless $stats;
    $stats->{queued}    //= 0;
    $stats->{queued_p0} //= 0;
    $stats->{proc_time} //= 0;

    # Take note of the job queue length
    my $qlen     = await $self->redis->llen('pricer_jobs');
    my $overflow = $qlen + $stats->{queued_p0} - $stats->{queued};
    $overflow = 0 if $overflow < 0;
    if ($overflow) {
        await $self->dequeue($overflow, "pricer_jobs");
    }
    my $qlen_p0     = await $self->redis->llen('pricer_jobs_p0');
    my $overflow_p0 = $qlen_p0 - $stats->{queued_p0};
    $overflow_p0 = 0 if $overflow_p0 < 0;
    if ($overflow_p0) {
        await $self->dequeue($overflow_p0, "pricer_jobs_p0");
    }

    # this one should be about 1/sec, if it's much less then it runs too long
    stats_inc('pricer_daemon.queue.stats_collector', {tags => ['tag:' . $self->internal_ip]});
    stats_gauge('pricer_daemon.queue.overflow',    $overflow + $overflow_p0, {tags => ['tag:' . $self->internal_ip]});
    stats_gauge('pricer_daemon.queue.overflow_p0', $overflow_p0,             {tags => ['tag:' . $self->internal_ip]});
    # the name is misleading, it's the number of proposals queued for pricing in the last second
    stats_gauge('pricer_daemon.queue.size', $stats->{queued}, {tags => ['tag:' . $self->internal_ip]});
    # this one is of somewhat questionable value because multiple process subs can execute concurrently
    stats_gauge('pricer_daemon.queue.time', 1000.0 * $stats->{proc_time}, {tags => ['tag:' . $self->internal_ip]});
    $self->metrics_redis->set(
        'pricer_daemon_queue_stats',
        encode_json_utf8({
                overflow => $overflow,
                size     => $stats->{queued},
                updated  => $now,
            }));
}

=head2 submit_unknown

We might get pricing requests for which we can't determine the symbol. Those
are most likely invalid, but we still should submit them about once a second to
price daemon.

=cut

async sub submit_unknown {
    my $self = shift;
    while (1) {
        await $self->loop->delay_future(at => int($self->loop->time) + 1);
        await $self->process('_UNKNOWN_');
    }
}

=head2 submit_noticks

Submits contracts for symbols for which we didn't have any ticks for 5 sec

=cut

async sub submit_noticks {
    my $self = shift;
    while (1) {
        await $self->loop->delay_future(at => int($self->loop->time) + 1);
        for my $sym (keys %{$self->{cache_by_symbol}}) {
            my $t = $self->loop->time;
            $self->{last_tick}{$sym} //= $t;
            if ($self->{last_tick}{$sym} + 4 < int($t)) {
                await $self->process($sym);
            }
        }
    }
}

=head2 process

Processes pricing jobs for a given symbol

=cut

async sub process {
    my ($self, $symbol, $tick) = @_;

    my $start     = $tick ? $tick->{received} : Time::HiRes::time();
    my $contracts = $self->{cache_by_symbol}{$symbol};
    if ($contracts) {
        await $self->submit_jobs($contracts, $tick);
        $self->{stats}{queued} += @$contracts;
    }
    my $now = Time::HiRes::time();
    $self->{stats}{proc_time} += $now - $start;
    $self->{last_tick}{$symbol} = $now;
    stats_timing('pricer_daemon.queue.process.time', 1000 * ($now - $start), {tags => ['tag:' . $self->internal_ip]});
}

=head2 run_contract_updater

runs a routine that updates the list of contracts in memory

=cut

async sub run_contract_updater {
    my $self = shift;
    while (1) {
        my $t = $self->loop->time;
        await $self->update_list_of_contracts;
        # on production it takes about 0.035sec to update the list of
        # contracts, the procedure is also rather CPU intensive. Ideally we
        # want the list of contracts to be updated continuously and we want to
        # pick up new ones as fast as possible, but we also don't want updating
        # list of contracts to affect other tasks. Hence we only update the
        # list once in 0.1sec. That also makes it update the contracts with the
        # same frequency in QA and in production.
        await $self->loop->delay_future(at => $t + 0.1);
    }
}

=head2 keep_poc_alive

keeps the POC_PARAMETERS keys for the contracts for which we stream prices alive

=cut

async sub keep_poc_alive {
    my $self = shift;
    while (1) {
        await $self->loop->delay_future(after => 4);
        my @active_contracts = keys %{$self->{contract_symbol}};
        my $redis            = $self->contract_redis;
        for my $c (@active_contracts) {
            my $key = join '::', 'POC_PARAMETERS', $c;
            $redis->expire($key, 60)->retain if (await $redis->ttl($key)) < 10;
        }
    }
}

=head2 update_list_of_contracts

scans through all the PRICER_ARGS keys in redis and groups them by their
symbol. If the key is for proposal, then the symbol comes directly from the
key, if the key refers to a contract, then we look up the contract detail and
use the symbol from there. To reduce the number of lookups we cache the
contract's symbols between the runs.

=cut

async sub update_list_of_contracts {
    my ($self) = @_;

    my $start = $self->loop->time;
    # lists of PRICER_ARGS by symbol
    my %cache_by_symbol;
    # mapping of contracts to symbols
    my %contract_symbol;
    # total number of key added
    my $total  = 0;
    my $cursor = 0;
    do {
        my $details = await $self->redis->scan(
            $cursor,
            match => "PRICER_ARGS::*",
            count => $self->keys_per_batch,
        );
        ($cursor, my $keys) = $details->@*;
        for my $key (@$keys) {
            my %params = decode_json_utf8($key =~ s/^PRICER_ARGS:://r)->@*;
            if ($params{contract_id} and $params{landing_company}) {
                # if we have a contract, then get contract details, find symbol
                # from there and store the key under that symbol
                my $ckey = join '::', $params{contract_id}, $params{landing_company};
                if (my $sym = $self->{contract_symbol}->{$ckey}) {
                    $contract_symbol{$ckey} = $sym;
                    push @{$cache_by_symbol{$sym}}, $key;
                    $total++;
                } else {
                    my $sym;
                    try {
                        $sym = await $self->symbol_for_contract($ckey);
                    } catch ($e) {
                        $log->warnf("no symbol for contract %s: %s", $ckey, $e);
                        $sym = '_UNKNOWN_';
                    }
                    $contract_symbol{$ckey} = $sym;
                    push @{$cache_by_symbol{$sym}}, $key;
                    $total++;
                }
            } elsif ($params{symbol}) {
                # if the symbol is stored in PRICER_ARGS then just use that symbol
                push @{$cache_by_symbol{$params{symbol}}}, $key;
                $total++;
            } else {
                $log->warnf("failed to find symbol for %s", $key);
            }
        }
    } while ($cursor);
    $self->{cache_by_symbol} = \%cache_by_symbol;
    $self->{contract_symbol} = \%contract_symbol;
    my $dur = $self->loop->time - $start;
    $self->{stats}{update_time} += $dur;
    stats_inc('pricer_daemon.queue.list_update.count', {tags => ['tag:' . $self->internal_ip]});
    stats_gauge('pricer_daemon.queue.list_update.records', $total, {tags => ['tag:' . $self->internal_ip]});
    stats_gauge('pricer_daemon.queue.list_update.time',    $dur,   {tags => ['tag:' . $self->internal_ip]});
}

=head2 symbol_for_contract

Takes the following parameters:

=over 4

=item * C<< $contract_key >> - numeric contract ID and landing company joined with '::'

=back

Returns a L<Future> which will resolve to a symbol for the contract.

=cut

async sub symbol_for_contract {
    my ($self, $contract_key) = @_;

    my $redis      = $self->contract_redis;
    my $params_key = join '::', ('POC_PARAMETERS', $contract_key);
    my $params     = await $redis->get($params_key)
        or die 'contract parameters not found';
    my %h = decode_json_utf8($params)->@*;
    if ($h{symbol}) {
        return $h{symbol};
    } elsif ($h{short_code}) {
        my $p = shortcode_to_parameters($h{short_code});
        die "no symbol in shortcode $h{short_code}: @{[$p->%*]}" unless $p->{underlying};
        return Finance::Underlying->by_symbol($p->{underlying})->symbol;
    } else {
        die "couldn't get symbol from '$params'";
    }
}

=head2 parameters_for_contract

Takes the following parameters:

=over 4

=item * C<< $contract_key >> - numeric contract ID and landing company joined with '::'

=back

Returns a L<Future> which will resolve to a hashref of contract parameters.

=cut

async sub parameters_for_contract {
    my ($self, $contract_key) = @_;

    my $redis      = $self->contract_redis;
    my $params_key = join '::', ('POC_PARAMETERS', $contract_key);
    my $params     = await $redis->get($params_key)
        or die 'Contract parameters not found';

    # Refreshes the expiry if TTL is unexpectedly low.
    # We don't need to wait for the ->expire step, that
    # can happen in the background.
    $redis->expire($params_key, 60)->retain if (await $redis->ttl($params_key)) < 10;

    return +{decode_json_utf8($params)->@*};
}

=head2 dequeue

Removes specified number of proposals from the pricer_jobs list and if
L</record_price_metrics> is set analyses pricing keys for the dequeued
proposals and generates some metrics.

=cut

async sub dequeue {
    my ($self, $count, $queue) = @_;

    my $deq = await $self->redis->rpop($queue, $count);
    return unless $deq and 0 + @$deq;
    return unless $self->record_price_metrics;
    my %queued;
    await fmap0(
        async sub {
            my $key = shift;

            try {
                my %params = decode_json_utf8($key =~ s/^PRICER_ARGS:://r)->@*;
                # Exclude proposal_array
                return if exists $params{barriers};

                # Retrieve extra information for open contracts
                if ($params{contract_id} and $params{landing_company}) {
                    my $ckey = join '::', $params{contract_id}, $params{landing_company};
                    my $poc_parameters = await $self->parameters_for_contract($ckey);
                    @params{keys %$poc_parameters} = values %$poc_parameters;
                }

                my $relative_shortcode = BOM::Pricing::v3::Utility::create_relative_shortcode(\%params);
                $queued{$relative_shortcode}++;
            } catch ($e) {
                $log->warnf('Failed to extract metrics for contract %s - %s', $key, $e);
                stats_inc('pricing.queue.invalid_contract');
            }
        },
        foreach    => $deq,
        concurrent => 32,
    );

    await Future->needs_all(map { $self->redis->hincrby('PRICE_METRICS::DEQUEUED', $_, $queued{$_}) } keys %queued);
}

1;
