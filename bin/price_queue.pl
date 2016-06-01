#!/usr/bin/env perl
use strict;
use warnings;
use BOM::System::RedisReplicated;
use DataDog::DogStatsd::Helper;
use Time::HiRes::Sleep::Until;


my $redis = BOM::System::RedisReplicated::redis_pricer;

while (Time::HiRes::Sleep::Until->new->epoch(time+1)) {
    $keys = $redis->scan_all(MATCH=>'Redis::Processor::*', COUNT=>1000000);

    DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.queue.size', (scalar @$keys));
    DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.queue.not_processed', $redis->llen('pricer_jobs'));
    $redis->del('pricer_jobs');
    $redis->push('pricer_jobs', @{$keys});
}

