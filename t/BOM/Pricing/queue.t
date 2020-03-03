#!/usr/bin/env perl
use strict;
use warnings;

use Test::Most;
use Test::Exception;
use Test::Warnings qw(warnings);

use Time::HiRes;
use YAML::XS;
use RedisDB;

my (%stats, %tags);

BEGIN {
    require DataDog::DogStatsd::Helper;
    no warnings 'redefine';
    *DataDog::DogStatsd::Helper::stats_gauge = sub {
        my ($key, $val, $tag) = @_;
        $stats{$key} = $val;
        ++$tags{$tag->{tags}[0]};
    };
    *DataDog::DogStatsd::Helper::stats_inc = sub {
        my ($key, $tag) = @_;
        $stats{$key}++;
        ++$tags{$tag->{tags}[0]};
    };
}

is_deeply(\%stats, {}, 'start with no metrics');
is_deeply(\%tags,  {}, 'start with no tags');

use BOM::Pricing::Queue;

# use a separate redis client for this test
my $redis        = RedisDB->new(YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml')->{write}->%*);
my $redis_shared = RedisDB->new(YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer-shared.yml')->{write}->%*);
my $queue;

# Sample pricer jobs
my @keys = (
    "PRICER_KEYS::[\"amount\",1000,\"basis\",\"payout\",\"contract_type\",\"PUT\",\"country_code\",\"ph\",\"currency\",\"AUD\",\"duration\",3,\"duration_unit\",\"m\",\"landing_company\",null,\"price_daemon_cmd\",\"price\",\"product_type\",\"basic\",\"proposal\",1,\"skips_price_validation\",1,\"subscribe\",1,\"symbol\",\"frxAUDJPY\"]",
    "PRICER_KEYS::[\"amount\",1000,\"basis\",\"payout\",\"contract_type\",\"CALL\",\"country_code\",\"ph\",\"currency\",\"AUD\",\"duration\",3,\"duration_unit\",\"m\",\"landing_company\",null,\"price_daemon_cmd\",\"price\",\"product_type\",\"basic\",\"proposal\",1,\"skips_price_validation\",1,\"subscribe\",1,\"symbol\",\"frxAUDJPY\"]",
    "PRICER_KEYS::[\"contract_id\",123,\"landing_company\",\"svg\",\"pricer_daemon_cmd\",\"bid\"]",
    "PRICER_KEYS::[\"amount\",1000,\"barriers\",[\"106.902\",\"106.952\",\"107.002\",\"107.052\",\"107.102\",\"107.152\",\"107.202\"],\"basis\",\"payout\",\"contract_type\",[\"PUT\",\"CALLE\"],\"country_code\",\"ph\",\"currency\",\"JPY\",\"date_expiry\",\"1522923300\",\"landing_company\",null,\"price_daemon_cmd\",\"price\",\"product_type\",\"multi_barrier\",\"proposal_array\",1,\"skips_price_validation\",1,\"subscribe\",1,\"symbol\",\"frxUSDJPY\",\"trading_period_start\",\"1522916100\"]",
    "PRICER_KEYS::[\"amount\",1000,\"barriers\",[\"106.902\",\"106.952\",\"107.002\",\"107.052\",\"107.102\",\"107.152\",\"107.202\"],\"basis\",\"payout\",\"contract_type\",[\"PUT\",\"CALLE\"],\"country_code\",\"ph\",\"currency\",\"JPY\",\"date_expiry\",\"1522923300\",\"landing_company\",null,\"price_daemon_cmd\",\"price\",\"product_type\",\"multi_barrier\",\"proposal_array\",1,\"skips_price_validation\",1,\"subscribe\",1,\"symbol\",\"frxEURCAD\",\"trading_period_start\",\"1522916100\"]",
);

my @contract_params = ([
    "CONTRACT_PARAMS::123::svg",
    "[\"short_code\",\"PUT_FRXAUDJPY_19.23_1583120649_1583120949_S0P_0\",\"contract_id\",\"123\",\"currency\",\"USD\",\"is_sold\",\"0\",\"landing_company\",\"svg\",\"price_daemon_cmd\",\"bid\",\"sell_time\",null]"
]);
$redis_shared->set($_->[0] => $_->[1]) for @contract_params;

subtest 'normal flow' => sub {
    $queue = new_ok(
        'BOM::Pricing::Queue',
        [
            priority    => 0,
            internal_ip => '1.2.3.4'
        ],
        'New BOM::Pricing::Queue processor'
    );

    $redis->set($_ => 1) for @keys;

    $queue->process;

    is($redis->llen('pricer_jobs'),            @keys,                            'keys added to pricer_jobs queue');
    is($stats{'pricer_daemon.queue.overflow'}, 0,                                'zero overflow reported in statd');
    is($stats{'pricer_daemon.queue.size'},     @keys,                            'keys waiting for processing in statsd');
    is((keys %tags)[0],                        "tag:@{[ $queue->internal_ip ]}", 'internal ip recorded as tag');

    like $redis->lrange('pricer_jobs', -1, -1)->[0], qr/"contract_id"/, 'bid contract is the first to rpop for being processed';
};

subtest 'overloaded daemon' => sub {
    # kill the subscriptions or they will be added again
    $redis->del($_) for @keys;

    $queue->process;

    is($stats{'pricer_daemon.queue.overflow'}, @keys, 'overflow correctly reported in statsd');
    is($stats{'pricer_daemon.queue.size'},     0,     'no keys pending processing in statsd');
};

subtest 'jobs processed by daemon' => sub {
    # Simulate the pricer daemon taking jobs
    $redis->del('pricer_jobs');
    $queue->process;

    is($stats{'pricer_daemon.queue.overflow'}, 0, 'zero overflow reported in statsd');
    is($stats{'pricer_daemon.queue.size'},     0, 'no keys pending processing in statsd');
};

subtest 'sleeping to next second' => sub {
    my $start = Time::HiRes::time();
    BOM::Pricing::Queue::_sleep_to_next_second();
    my $end = Time::HiRes::time();
    cmp_ok($end - $start, '<', 1, 'time taken to sleep is less than a second');
};

subtest 'priority_queue' => sub {
    my $pid = fork // die "Couldn't fork";
    unless ($pid) {
        sleep 1;
        note "publishing high priority prices in fork";
        $redis->publish('high_priority_prices', $_) for @keys;
        exit;
    }

    $queue = new_ok(
        'BOM::Pricing::Queue',
        [
            priority => 1,
            , internal_ip => '1.2.3.4'
        ],
        'New priority BOM::Pricing::Queue processor'
    );
    # need to do 5 times because initial redis reply will be subscription confirmation
    $queue->process for (0 .. @keys);
    is($redis->llen('pricer_jobs_priority'),        @keys, 'keys added to pricer_jobs_priority queue');
    is($stats{'pricer_daemon.priority_queue.recv'}, @keys, 'receive stats updated in statsd');
    is($stats{'pricer_daemon.priority_queue.send'}, @keys, 'send stats updated in statsd');
};

done_testing;
