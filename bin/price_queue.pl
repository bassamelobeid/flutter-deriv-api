#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::Platform::RedisReplicated;
use DataDog::DogStatsd::Helper;
use Time::HiRes;
use LWP::Simple;
use List::UtilsBy qw(extract_by);
use JSON::MaybeXS;
use Log::Any '$log', default_adapter => ['Stdout', log_level => 'warn'];
use Getopt::Long;
use Try::Tiny;
use Path::Tiny ();

no indirect;

=encoding utf-8

=head1 NAME

price_queue.pl - Process queue for the BOM pricer daemon

=head1 SYNOPSIS

    price_queue.pl [--priority]

=head1 DESCRIPTION

This script runs as a daemon to process the BOM pricer daemon's Redis queues.

=head1 OPTIONS

=over 8

=item B<--priority>

Process the priority queue instead of the regular queue.

=cut

my $internal_ip = get("http://169.254.169.254/latest/meta-data/local-ipv4");
my $redis       = BOM::Platform::RedisReplicated::redis_pricer;
my $redis_sub   = BOM::Platform::RedisReplicated::redis_pricer(timeout => 60);
my $iteration   = 0;

GetOptions
    'pid-file=s' => \my $pid_file,
    'priority'   => \my $priority;

Path::Tiny->new($pid_file)->spew($$) if $pid_file;

_subscribe_priority_queue() if $priority;

while (1) {
    if ($priority) {
        _process_priority_queue();
    } else {
        _process_price_queue();
    }
}

exit;

sub _subscribe_priority_queue {
    $log->trace('subscribing to high_priority_prices channel...');
    $redis->subscribe(
        high_priority_prices => sub {
            my (undef, $channel, $pattern, $message) = @_;
            DataDog::DogStatsd::Helper::stats_inc('pricer_daemon.priority_queue.recv', {tags => ['tag:' . $internal_ip]});
            $log->debug('received message, updating pricer_jobs_priority: ', {message => $message});
            $redis_sub->lpush('pricer_jobs_priority', $message);
            $log->debug('pricer_jobs_priority updated.');
            DataDog::DogStatsd::Helper::stats_inc('pricer_daemon.priority_queue.send', {tags => ['tag:' . $internal_ip]});
        });

    return undef;
}

sub _process_priority_queue {
    $log->trace('processing priority price_queue...');
    try {
        $redis->get_reply;
    }
    catch {
        $log->warnf("Caught error on priority queue subscription: %s", $_);
        # resubscribe if our $redis handle timed out
        _subscribe_priority_queue() if /not waiting for reply/;
    };

    return undef;
}

sub _sleep_to_next_second {
    my $t = Time::HiRes::time();

    my $sleep = 1 - ($t - int($t));
    $log->debugf('sleeping at %s for %s secs...', $t, $sleep);
    Time::HiRes::usleep($sleep * 1_000_000);

    return undef;
}

sub _process_price_queue {
    $log->trace('processing regular price_queue...');
    _sleep_to_next_second();
    my $overflow = $redis->llen('pricer_jobs');

    # If we didn't manage to process everything within 1s, we'll allow 1s extra - this will cause price update rates to
    # be halved on the UI.
    if ($overflow) {
        $log->debugf('got pricer_jobs overflow: %s', $overflow);
        _sleep_to_next_second();
    }

    # We prepend short_code where possible, so sorting means we should get similar contracts together,
    # which should help with portfolio table update synchronisation
    my @keys = sort @{
        $redis->scan_all(
            MATCH => 'PRICER_KEYS::*',
            COUNT => 20000
        )};

    # Separate out JP prices, they're handled by different servers and we expect a near-constant load for them
    my @jp_keys = extract_by {
        /"landing_company","japan/
    }
    @keys;

    my $not_processed = $redis->llen('pricer_jobs');
    $log->debugf('got pricer_jobs not processed: %s', $not_processed) if $not_processed;

    $log->trace('pricer_jobs queue updating...');
    $redis->del('pricer_jobs');
    $redis->lpush('pricer_jobs', @keys) if @keys;
    $log->debug('pricer_jobs queue updated.');

    # For JP pricing we're using a 3-second interval by default: we refresh the queue once for every 3 cycles on the main
    # queue. Note that this means the actual time we start the JP pricing could be on odd seconds, even seconds, or we may even
    # update once every 4 seconds when the system is under particularly heavy load.
    unless ($iteration++ % 2) {
        $log->trace('pricer_jobs_jp queue updating...');
        DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.queue_jp.size', 0 + @jp_keys, {tags => ['tag:' . $internal_ip]});
        DataDog::DogStatsd::Helper::stats_gauge(
            'pricer_daemon.queue_jp.not_processed',
            $redis->llen('pricer_jobs_jp'),
            {tags => ['tag:' . $internal_ip]});
        $redis->del('pricer_jobs_jp');
        $redis->lpush('pricer_jobs_jp', @jp_keys) if @jp_keys;
        $log->debug('pricer_jobs_jp queue updated.');
    }
    DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.queue.overflow',      $overflow,      {tags => ['tag:' . $internal_ip]});
    DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.queue.size',          0 + @keys,      {tags => ['tag:' . $internal_ip]});
    DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.queue.not_processed', $not_processed, {tags => ['tag:' . $internal_ip]});

    $log->trace('pricer_daemon_queue_stats updating...');
    $redis->set(
        'pricer_daemon_queue_stats',
        JSON::MaybeXS->new->encode({
                overflow      => $overflow,
                not_processed => $not_processed,
                size          => 0 + @keys,
                updated       => time,
            }));
    $log->debug('pricer_daemon_queue_stats updated.');

    return undef;
}

