#!/usr/bin/env perl
use strict;
use warnings;

use Test::Most;
use Test::Exception;
use Test::Warnings qw(warnings);

use Path::Tiny;
use RedisDB;
use Time::HiRes qw(CLOCK_REALTIME clock_gettime alarm);
use YAML::XS;

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
use BOM::Pricing::PriceDaemon;

subtest 'priority scoring' => sub {
    # This is a little too tied to the implementation right now, but
    # it's better than nothing
    my $params = {
        price_daemon_cmd       => 'bid',
        real_money             => '1',
        duration_unit          => 's',
        duration               => '59',
        skips_price_validation => '1',
    };
    my $max_score = BOM::Pricing::Queue::score_for_parameters($params);
    cmp_ok($max_score, '==', 15554, 'Our example is the current max score possible');
    my $min_score = BOM::Pricing::Queue::score_for_parameters();
    cmp_ok($min_score, '==', 1, 'Even forgetting to send in parameters does not error, scores 1');
    $params->{underlying} = 'frxUSDJPY';
    cmp_ok(BOM::Pricing::Queue::score_for_parameters($params), '==', $max_score, 'Adding in an unconsidered parameter does not change score');
    $params->{skips_price_validation} = '0';
    my $skip_score = BOM::Pricing::Queue::score_for_parameters($params);
    cmp_ok($skip_score, '<', $max_score, 'String-y zeros are correctly interpreted as false');
    $params->{skips_price_validation} = '1';
    $params->{duration}               = 61;
    my $long_score = BOM::Pricing::Queue::score_for_parameters($params);
    cmp_ok($long_score, '<', $skip_score, 'Long duration and skipping validation is less important than short and validated');
    $params->{duration}      = 1;
    $params->{duration_unit} = 'h';
    cmp_ok(BOM::Pricing::Queue::score_for_parameters($params), '==', $long_score, 'Duration and units work together to determine long/short');
};

# use a separate redis client for this test
my $redis = RedisDB->new(YAML::XS::LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml')->{write}->%*);
my $queue;

# Sample pricer jobs
my @keys = (
    "PRICER_KEYS::[\"amount\",1000,\"basis\",\"payout\",\"contract_type\",\"PUT\",\"country_code\",\"ph\",\"currency\",\"AUD\",\"duration\",3,\"duration_unit\",\"m\",\"landing_company\",null,\"price_daemon_cmd\",\"price\",\"product_type\",\"basic\",\"proposal\",1,\"skips_price_validation\",1,\"subscribe\",1,\"symbol\",\"frxAUDJPY\"]",
    "PRICER_KEYS::[\"amount\",1000,\"basis\",\"payout\",\"contract_type\",\"CALL\",\"country_code\",\"ph\",\"currency\",\"AUD\",\"duration\",3,\"duration_unit\",\"m\",\"landing_company\",null,\"price_daemon_cmd\",\"price\",\"product_type\",\"basic\",\"proposal\",1,\"skips_price_validation\",1,\"subscribe\",1,\"symbol\",\"frxAUDJPY\"]",
    # The below is set to sort first by priority, despite appearing third here
    "PRICER_KEYS::[\"amount\",1000,\"barriers\",[\"106.902\",\"106.952\",\"107.002\",\"107.052\",\"107.102\",\"107.152\",\"107.202\"],\"basis\",\"payout\",\"contract_type\",[\"PUT\",\"CALLE\"],\"country_code\",\"ph\",\"currency\",\"JPY\",\"date_expiry\",\"1522923300\",\"landing_company\",null,\"price_daemon_cmd\",\"bid\",\"product_type\",\"multi_barrier\",\"proposal_array\",1,\"real_money\",1,\"skips_price_validation\",1,\"subscribe\",1,\"symbol\",\"frxUSDJPY\",\"trading_period_start\",\"1522916100\"]",
    "PRICER_KEYS::[\"amount\",1000,\"barriers\",[\"106.902\",\"106.952\",\"107.002\",\"107.052\",\"107.102\",\"107.152\",\"107.202\"],\"basis\",\"payout\",\"contract_type\",[\"PUT\",\"CALLE\"],\"country_code\",\"ph\",\"currency\",\"JPY\",\"date_expiry\",\"1522923300\",\"landing_company\",null,\"price_daemon_cmd\",\"price\",\"product_type\",\"multi_barrier\",\"proposal_array\",1,\"skips_price_validation\",1,\"subscribe\",1,\"symbol\",\"frxUSDJPY\",\"trading_period_start\",\"1522916100\"]",
    "PRICER_KEYS::[\"amount\",1000,\"barriers\",[\"106.902\",\"106.952\",\"107.002\",\"107.052\",\"107.102\",\"107.152\",\"107.202\"],\"basis\",\"payout\",\"contract_type\",[\"PUT\",\"CALLE\"],\"country_code\",\"ph\",\"currency\",\"JPY\",\"date_expiry\",\"1522923300\",\"landing_company\",null,\"price_daemon_cmd\",\"price\",\"product_type\",\"multi_barrier\",\"proposal_array\",1,\"skips_price_validation\",1,\"subscribe\",1,\"symbol\",\"frxEURCAD\",\"trading_period_start\",\"1522916100\"]",
);

subtest 'normal flow' => sub {
    $queue = new_ok('BOM::Pricing::Queue', [internal_ip => '1.2.3.4'], 'New BOM::Pricing::Queue processor');
    is($queue->add(@keys), scalar(@keys), 'All keys added to pending');
    eq_or_diff([sort $queue->reindexed_channels], [sort @keys], 'Index contains newly added items');
    # See comment in sample jobs list to understand the indices here
    isnt(($queue->channels_from_index)[0], $keys[2], "Insertion order is not by desired priority");
    my $review_count = 0;
    until ($queue->clear_review_queue) {
        $review_count++;
    }
    cmp_ok($review_count, '==', scalar(@keys), 'Reviewed one key per call');
    # See comment in sample jobs list to understand the indices here
    is(($queue->channels_from_index)[0], $keys[2], "Real money is sorted first now");
    $queue->process;

    my @index_channels = $queue->channels_from_index;
    my @keys_channels  = $queue->channels_from_keys;
    is(scalar(@index_channels),                     @keys,                            'Channels queued in index');
    is(scalar(@keys_channels),                      @keys,                            'Channel keys exist');
    is($stats{'pricer_daemon.queue.overflow'},      0,                                'zero overflow reported in statd');
    is($stats{'pricer_daemon.queue.size'},          @keys,                            'keys waiting for processing in statsd');
    is($stats{'pricer_daemon.queue.not_processed'}, 0,                                'zero not_processed reported in statsd');
    is((keys %tags)[0],                             "tag:@{[ $queue->internal_ip ]}", 'internal ip recorded as tag');
};

subtest 'overloaded daemon' => sub {
    # kill the subscriptions or they will be added again
    $redis->del('pricer_channels');
    $redis->del($_) for @keys;

    $queue->process;
    is($stats{'pricer_daemon.queue.overflow'},      @keys, 'overflow correctly reported in statsd');
    is($stats{'pricer_daemon.queue.size'},          0,     'no keys pending processing in statsd');
    is($stats{'pricer_daemon.queue.not_processed'}, @keys, 'not_processed correctly reported in statsd');
};

subtest 'jobs processed by daemon' => sub {
    # Simulate the pricer daemon taking jobs
    $redis->del('pricer_jobs');
    $queue->process;

    is($stats{'pricer_daemon.queue.overflow'},      0, 'zero overflow reported in statsd');
    is($stats{'pricer_daemon.queue.size'},          0, 'no keys pending processing in statsd');
    is($stats{'pricer_daemon.queue.not_processed'}, 0, 'zero not_processed reported in statsd');

};

subtest 'prepare for next interval' => sub {
    my $start = clock_gettime(CLOCK_REALTIME);
    $queue->_prep_for_next_interval;
    my $end = clock_gettime(CLOCK_REALTIME);
    cmp_ok($end - $start, '<=', $queue->pricing_interval, 'time taken to sleep is less than a pricing interval');
};

subtest 'daemon loading and unloading' => sub {
    note("These are largely correct in construction but cannot be priced in most environments");
    # This is ugly, but the PD code is largely untestable itself.
    my $key_file  = path(__FILE__)->sibling('pricer_keys-green-live-20191022.txt');
    my @load_keys = $key_file->lines_utf8({chomp => 1});
    my $load_size = @load_keys;
    is($queue->add(@load_keys), $load_size, 'All keys added to pending');
    {
        # We know we cannot really price things most places, so don't emit so much noise.
        $SIG{__WARN__} = sub { };
        $queue->process;
        is($queue->active_job_count, $load_size, 'All keys converted to jobs');
        my $daemon = new_ok('BOM::Pricing::PriceDaemon', [tags => ['tag:1.2.3.4']], 'Test daemon');
        local $SIG{ALRM} = sub { $daemon->stop; };
        no strict 'refs';
        # Skip pricing, just return placeholder value(s)
        # Including `rpc_time` makes the serialisation and publish not upset with an
        # empty hashref this can be expanded/adjusted to create a more realistic mock
        local *{"BOM::Pricing::PriceDaemon::process_job"} = sub { +{rpc_time => 10,}; };
        alarm(10);
        # This is an MVP configuration, can be exxpanded to improve realism as needed
        $daemon->run(
            queues       => ['pricer_jobs'],
            ip           => '1.2.3.4',
            fork_index   => 0,
            pid          => $$,
            redis        => $redis,
            queue_obj    => $queue,
            wait_timeout => 1,
        );
    }
    my $active = $queue->active_job_count;
    cmp_ok($active, '<=', $load_size / 2, 'Consumed at least half the list');
    my @index_channels = $queue->channels_from_index;
    note 'We do not want an explicit test here, because we might be able to actually price';
    note 'Active: ' . $active;
    note 'Pending: ' . scalar(@index_channels);

    my @keys_channels = $queue->channels_from_keys;
    eq_or_diff([sort @index_channels], [sort @keys_channels], 'Index and keyspace are in sync');
};

done_testing;
