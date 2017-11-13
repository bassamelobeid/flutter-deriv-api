#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::Platform::RedisReplicated;
use DataDog::DogStatsd::Helper;
use List::MoreUtils qw(uniq);
use Time::HiRes;
use LWP::Simple;
use List::UtilsBy qw(extract_by);
use JSON::MaybeXS;

my $internal_ip = get("http://169.254.169.254/latest/meta-data/local-ipv4");
my $redis       = BOM::Platform::RedisReplicated::redis_pricer;

sub _sleep_to_next_second {
    my $t = Time::HiRes::time();

    my $sleep = 1 - ($t - int($t));
    Time::HiRes::usleep($sleep * 1_000_000);
}

my $iteration = 0;
while (1) {
    _sleep_to_next_second();
    my $overflow = $redis->llen('pricer_jobs');

    # If we didn't manage to process everything within 1s, we'll allow 1s extra - this will cause price update rates to
    # be halved on the UI.
    if ($overflow) {
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

    $redis->del('pricer_jobs');
    $redis->lpush('pricer_jobs', @keys) if @keys;

    # For JP pricing we're using a 3-second interval by default: we refresh the queue once for every 3 cycles on the main
    # queue. Note that this means the actual time we start the JP pricing could be on odd seconds, even seconds, or we may even
    # update once every 4 seconds when the system is under particularly heavy load.
    unless ($iteration++ % 2) {
        DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.queue_jp.size', 0 + @jp_keys, {tags => ['tag:' . $internal_ip]});
        DataDog::DogStatsd::Helper::stats_gauge(
            'pricer_daemon.queue_jp.not_processed',
            $redis->llen('pricer_jobs_jp'),
            {tags => ['tag:' . $internal_ip]});
        $redis->del('pricer_jobs_jp');
        $redis->lpush('pricer_jobs_jp', @jp_keys) if @jp_keys;
    }
    DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.queue.overflow',      $overflow,      {tags => ['tag:' . $internal_ip]});
    DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.queue.size',          0 + @keys,      {tags => ['tag:' . $internal_ip]});
    DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.queue.not_processed', $not_processed, {tags => ['tag:' . $internal_ip]});

    $redis->set(
        'pricer_daemon_queue_stats',
        JSON::MaybeXS->new->encode({
                overflow      => $overflow,
                not_processed => $not_processed,
                size          => 0 + @keys,
                updated       => time,
            }));
}

