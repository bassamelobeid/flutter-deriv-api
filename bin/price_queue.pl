#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::Config::RedisReplicated;
use DataDog::DogStatsd::Helper qw(stats_inc stats_gauge);
use Time::HiRes qw(time clock_nanosleep CLOCK_REALTIME);
use LWP::Simple 'get';
use List::UtilsBy qw(extract_by);
use JSON::MaybeXS;
use Log::Any '$log', default_adapter => ['Stdout', log_level => 'warn'];
use Getopt::Long 'GetOptions';
use Try::Tiny;
use Path::Tiny 'path';

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
my $redis       = BOM::Config::RedisReplicated::redis_pricer;
my $redis_sub   = BOM::Config::RedisReplicated::redis_pricer(timeout => 60);
my $iteration   = 0;

GetOptions
    'pid-file=s' => \my $pid_file,
    'priority'   => \my $priority;

path($pid_file)->spew($$) if $pid_file;

_subscribe_priority_queue() if $priority;

my $queue_processor = $priority ? \&_process_priority_queue : \&_process_price_queue;
$queue_processor->() while 1;

exit;

sub _subscribe_priority_queue {
    $log->trace('subscribing to high_priority_prices channel...');
    $redis->subscribe(
        high_priority_prices => sub {
            my (undef, $channel, $pattern, $message) = @_;
            stats_inc('pricer_daemon.priority_queue.recv', {tags => ['tag:' . $internal_ip]});
            $log->debug('received message, updating pricer_jobs_priority: ', {message => $message});
            $redis_sub->lpush('pricer_jobs_priority', $message);
            $log->debug('pricer_jobs_priority updated.');
            stats_inc('pricer_daemon.priority_queue.send', {tags => ['tag:' . $internal_ip]});
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
    my $t = time();

    my $sleep = 1 - ($t - int($t));
    $log->debugf('sleeping at %s for %s secs...', $t, $sleep);
    clock_nanosleep(CLOCK_REALTIME, $sleep * 1_000_000_000);

    return undef;
}
=head2 _process_price_queue

Scans Redis for incoming requests and places them on the appropriate queue for the pricer daemon. 
Separates the ask/price and bid queues for performance
Takes no Arguments 


Returns undef

=cut

sub _process_price_queue {
    $log->trace('processing price_queue...');
    _sleep_to_next_second();
    my $overflow_count_price = $redis->llen('pricer_jobs');
    my $overflow_count_bid = $redis->llen('pricer_jobs_bid');
    # If we didn't manage to process everything within 1s, we'll allow 1s extra - this will cause price update rates to
    # be halved on the UI.
    if ($overflow_count_price or $overflow_count_bid) {
        my $msg = 'got pricer queue overflow: %s for queue %s';
        $log->debugf($msg, $overflow_count_price , 'price');
        $log->debugf($msg, $overflow_count_bid , 'bid');
        _sleep_to_next_second();
    }

    # We prepend short_code where possible, so sorting means we should get similar contracts together,
    # which should help with portfolio table update synchronisation
    my @keys = sort @{
        $redis->scan_all(
            MATCH => 'PRICER_KEYS::*',
            COUNT => 20000
        )};
        my @bid_keys = extract_by {
        /"price_daemon_cmd","bid"/
    }
    @keys;

    _update_queue('pricer_jobs', \@keys, $overflow_count_price);
    _update_queue('pricer_jobs_bid', \@bid_keys, $overflow_count_bid);
    return undef;
}

=head2 _update_queue

Updates Redis queues and logs stats.  We use Redis lists for our queues 
Takes the following arguments as parameters

=over 4

=item C<$queue_name>  String  name of redis queue (These will be processed by the pricer daemon)

=item C<$keys>  arrayref of keys to add to the destination queue.
 
=item C<$overflow_count> is the number of jobs still on the destination queue that have not been processed

=back

Returns undef

=cut

sub _update_queue {
    my ($queue_name, $key, $overflow_count) = @_;
    my @keys = @$key;
    my $not_processed = $redis->llen($queue_name);
    $log->debugf('got %s not processed: %s', $queue_name, $not_processed) if $not_processed;

    $log->trace("$queue_name queue updating...");
    $redis->del($queue_name);
    $redis->lpush($queue_name, @keys) if @keys;
    $log->debug("$queue_name queue updated with ".scalar(@keys)." keys");

    stats_gauge('pricer_daemon.queue.overflow',      $overflow_count,      {tags => ['tag:' . $internal_ip, 'queue_name' => $queue_name]});
    stats_gauge('pricer_daemon.queue.size',          0 + @keys,      {tags => ['tag:' . $internal_ip, 'queue_name' => $queue_name]});
    stats_gauge('pricer_daemon.queue.not_processed', $not_processed, {tags => ['tag:' . $internal_ip, 'queue_name' => $queue_name]});

    $log->trace('pricer_daemon_queue_stats updating...');
    $redis->set(
        'pricer_daemon_queue_stats_'.$queue_name,
        JSON::MaybeXS->new->encode({
                overflow      => $overflow_count,
                not_processed => $not_processed,
                size          => 0 + @keys,
                updated       => time,
            }));
    $log->debug('pricer_daemon_queue_stats updated.');

    return undef;
}

