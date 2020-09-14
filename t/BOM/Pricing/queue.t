#!/usr/bin/env perl
use strict;
use warnings;

use Test::Most;
use Test::Exception;
use Test::Warnings qw(warnings);

use Log::Any::Adapter qw(TAP);

use Time::HiRes;
use YAML::XS;
use RedisDB;
use IO::Async::Loop;

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

# This module is used by BOM::Pricing::Queue.
# And we want to switch redis database AFTER this module is load in the compiling phrase
# But in this script BOM::Pricing::Queue is loaded at run time phrase.
# So we need to use it obviously. Please refer BOM::Test INIT block
# This line is put here with `require` command to make thing clearer and maintenance easier
use Net::Async::Redis;
# Load this *after* our stats setup, so that the datadog override is in place
require BOM::Pricing::Queue;

# use a separate redis client for this test
my $redis        = RedisDB->new(YAML::XS::LoadFile('/etc/rmg/redis-pricer.yml')->{write}->%*);
my $redis_shared = RedisDB->new(YAML::XS::LoadFile('/etc/rmg/redis-pricer-shared.yml')->{write}->%*);

my $loop  = IO::Async::Loop->new;
my $queue = new_ok('BOM::Pricing::Queue', [internal_ip => '1.2.3.4'], 'New BOM::Pricing::Queue processor');
$loop->add($queue);

# Sample pricer jobs
my @keys = (
    q{PRICER_KEYS::["amount",1000,"basis","payout","contract_type","PUT","country_code","ph","currency","AUD","duration",3,"duration_unit","m","landing_company",null,"price_daemon_cmd","price","product_type","basic","proposal",1,"skips_price_validation",1,"subscribe",1,"symbol","frxAUDJPY"]},
    q{PRICER_KEYS::["amount",1000,"basis","payout","contract_type","CALL","country_code","ph","currency","AUD","duration",3,"duration_unit","m","landing_company",null,"price_daemon_cmd","price","product_type","basic","proposal",1,"skips_price_validation",1,"subscribe",1,"symbol","frxAUDJPY"]},
    q{PRICER_KEYS::["contract_id",123,"landing_company","svg","price_daemon_cmd","bid"]},
    q{PRICER_KEYS::["amount",1000,"barriers",["106.902","106.952","107.002","107.052","107.102","107.152","107.202"],"basis","payout","contract_type",["PUT","CALLE"],"country_code","ph","currency","JPY","date_expiry","1522923300","landing_company",null,"price_daemon_cmd","price","product_type","multi_barrier","proposal_array",1,"skips_price_validation",1,"subscribe",1,"symbol","frxUSDJPY","trading_period_start","1522916100"]},
    q{PRICER_KEYS::["amount",1000,"barriers",["106.902","106.952","107.002","107.052","107.102","107.152","107.202"],"basis","payout","contract_type",["PUT","CALLE"],"country_code","ph","currency","JPY","date_expiry","1522923300","landing_company",null,"price_daemon_cmd","price","product_type","multi_barrier","proposal_array",1,"skips_price_validation",1,"subscribe",1,"symbol","frxEURCAD","trading_period_start","1522916100"]},
);

my @contract_params = ([
    q{CONTRACT_PARAMS::123::svg},
    q{["short_code","PUT_FRXAUDJPY_19.23_1583120649_1583120949_S0P_0","contract_id","123","currency","USD","is_sold","0","landing_company","svg","price_daemon_cmd","bid","sell_time",null]}
]);
$redis_shared->set($_->[0] => $_->[1]) for @contract_params;

subtest 'normal flow' => sub {

    $redis->set($_ => 1) for @keys;

    $queue->process->get;

    is($redis->llen('pricer_jobs'),            @keys,                            'keys added to pricer_jobs queue');
    is($stats{'pricer_daemon.queue.overflow'}, 0,                                'zero overflow reported in statd');
    is($stats{'pricer_daemon.queue.size'},     @keys,                            'keys waiting for processing in statsd');
    is((keys %tags)[0],                        "tag:@{[ $queue->internal_ip ]}", 'internal ip recorded as tag');

    like $redis->lrange('pricer_jobs', -1, -1)->[0], qr/"contract_id"/, 'bid contract is the first to rpop for being processed';
};

subtest 'overloaded daemon' => sub {
    # kill the subscriptions or they will be added again
    $redis->del($_) for @keys;

    $queue->process->get;

    is($stats{'pricer_daemon.queue.overflow'}, @keys, 'overflow correctly reported in statsd');
    is($stats{'pricer_daemon.queue.size'},     0,     'no keys pending processing in statsd');
};

subtest 'jobs processed by daemon' => sub {
    # Simulate the pricer daemon taking jobs
    $redis->del('pricer_jobs');
    $queue->process->get;

    is($stats{'pricer_daemon.queue.overflow'}, 0, 'zero overflow reported in statsd');
    is($stats{'pricer_daemon.queue.size'},     0, 'no keys pending processing in statsd');
};

subtest 'pricing interval stability' => sub {
    $queue->configure(pricing_interval => 1.0);
    note 'Repeating next test 5 times to confirm stability';
    for (1 .. 5) {
        my $start = Time::HiRes::time();
        $queue->next_tick->get;
        my $end = Time::HiRes::time();
        cmp_ok($end - $start,    '<=', 1.1 * $queue->pricing_interval, 'time taken to sleep is acceptably close to pricing interval');
        cmp_ok($end - int($end), '<=', 0.05,                           'next interval starts within 50ms of the start of the second');
    }
};

subtest 'sleeping to next interval' => sub {
    for my $interval (qw(0.25 0.5 1.2)) {
        $queue->configure(pricing_interval => $interval);
        note 'Repeating next test 5 times with interval ' . $interval . 's to confirm stability';
        for (1 .. 5) {
            my $start = Time::HiRes::time();
            $queue->next_tick->get;
            my $end = Time::HiRes::time();
            cmp_ok(
                $end - $start,
                '<=',
                1.05 * $queue->pricing_interval,
                'time taken to sleep does not exceed ' . $interval . 's pricing interval by too much'
            );
        }
    }
};

done_testing;
