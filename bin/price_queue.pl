#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::System::RedisReplicated;
use DataDog::DogStatsd::Helper;
use List::MoreUtils qw(uniq);
use Time::HiRes;
use LWP::Simple;

my $internal_ip = get("http://169.254.169.254/latest/meta-data/local-ipv4");
my $redis = BOM::System::RedisReplicated::redis_pricer;

sub _sleep_to_next_second {
    my $t = Time::HiRes::time();

    my $sleep = 1 - ($t - int($t));
    Time::HiRes::usleep($sleep * 1_000_000);
}

while (1) {
    _sleep_to_next_second();
    my $overflow = $redis->llen('pricer_jobs');
    DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.queue.overflow', $overflow, {tags => ['tag:' . $internal_ip]});

    # If we didn't manage to process everything within 1s, we'll allow 1s extra - this will cause price update rates to
    # be halved on the UI.
    if($overflow) {
        _sleep_to_next_second();
    }

    my $keys = $redis->scan_all(
        MATCH => 'PRICER_KEYS::*',
        COUNT => 20000
    );

    DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.queue.size', (scalar @$keys), {tags => ['tag:' . $internal_ip]});
    DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.queue.not_processed', $redis->llen('pricer_jobs'), {tags => ['tag:' . $internal_ip]});

    $redis->del('pricer_jobs');
    $redis->lpush('pricer_jobs', @{$keys}) if scalar @{$keys} > 0;
}
