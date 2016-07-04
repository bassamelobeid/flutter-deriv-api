#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::System::RedisReplicated;
use DataDog::DogStatsd::Helper;
use List::MoreUtils qw(uniq);
use Time::HiRes;

my $redis = BOM::System::RedisReplicated::redis_pricer;

while (1) {
    my $t = Time::HiRes::time();
    # Sleep until start of next second
    my $sleep = 1 - ($t - int($t));
    Time::HiRes::usleep($sleep * 1_000_000);

    my $keys = $redis->scan_all(
        MATCH => 'PRICER_KEYS::*',
        COUNT => 20000
    );

    DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.queue.size', (scalar @$keys));
    DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.queue.not_processed', $redis->llen('pricer_jobs'));

    $redis->del('pricer_jobs');
    $redis->lpush('pricer_jobs', @{$keys}) if scalar @{$keys} > 0;
}

