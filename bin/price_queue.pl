#!/usr/bin/env perl
use strict;
use warnings;
use BOM::System::RedisReplicated;
use DataDog::DogStatsd::Helper;
use Time::HiRes::Sleep::Until;


my $redis = BOM::System::RedisReplicated::redis_pricer;

while (Time::HiRes::Sleep::Until->new->epoch(time+1)) {
    my $rc = $redis->eval(<<'LUA', 0);
    local ql=redis.call('LLEN', 'pricer_jobs')
    redis.call('DEL', 'pricer_jobs')
    return {
        ql,
        redis.call('RPUSH', 'pricer_jobs',
                   unpack(redis.call('KEYS', 'Redis::Processor::*')))
    }
LUA
    DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.queue.not_processed', $rc->[0]);
    DataDog::DogStatsd::Helper::stats_gauge('pricer_daemon.queue.size', $rc->[1]);
}
