#!/usr/bin/env perl
use strict;
use warnings;
use feature 'state';

use Test::MockObject;
use Test::Most;
use Test::Exception;
use Test::Warnings qw(warnings);

use DDP;    # For `np` notes
use List::Util qw( uniq );
use Path::Tiny;
use RedisDB;
use Time::HiRes qw(CLOCK_REALTIME clock_gettime alarm);
use Try::Tiny;
use YAML::XS;

use BOM::Pricing::v3::Utility;

my (%stats, %tags);

BEGIN {
    require DataDog::DogStatsd::Helper;
    no warnings 'redefine';
    *DataDog::DogStatsd::Helper::stats_gauge = sub {
        my ($key, $val, $tag) = @_;
        $stats{$key} = $val;
        ++$tags{$tag->{tags}[0]} if $tag->{tags};
    };
    *DataDog::DogStatsd::Helper::stats_inc = sub {
        my ($key, $tag) = @_;
        $stats{$key}++;
        ++$tags{$tag->{tags}[0]} if $tag->{tags};
    };
}

is_deeply(\%stats, {}, 'start with no metrics');
is_deeply(\%tags,  {}, 'start with no tags');

use BOM::Pricing::Queue;
use BOM::Pricing::PriceDaemon;

my $sfp = \&BOM::Pricing::Queue::score_for_parameters;

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
    my $max_score = $sfp->($params);
    cmp_ok($max_score, '==', 15554, 'Our example is the current max score possible');
    my $min_score = $sfp->();
    cmp_ok($min_score, '==', 1, 'Even forgetting to send in parameters does not error, scores 1');
    $params->{underlying} = 'frxUSDJPY';
    cmp_ok($sfp->($params), '==', $max_score, 'Adding in an unconsidered parameter does not change score');
    $params->{skips_price_validation} = '0';
    my $skip_score = $sfp->($params);
    cmp_ok($skip_score, '<', $max_score, 'String-y zeros are correctly interpreted as false');
    $params->{skips_price_validation} = '1';
    $params->{duration}               = 61;
    my $long_score = $sfp->($params);
    cmp_ok($long_score, '<', $skip_score, 'Long duration and skipping validation is less important than short and validated');
    $params->{duration}      = 1;
    $params->{duration_unit} = 'h';
    cmp_ok($sfp->($params), '==', $long_score, 'Duration and units work together to determine long/short');
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
    $queue = new_ok(
        'BOM::Pricing::Queue',
        [
            internal_ip      => '1.2.3.4',
            pricing_interval => 0.125
        ],
        'New BOM::Pricing::Queue processor'
    );
    cmp_ok($queue->pricing_interval, '==', 0.125, 'pricing_interval set at start-up');
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
    my @load_keys = uniq map { $_->lines_utf8({chomp => 1}) } (path(__FILE__)->parent->children(qr/^pricer_keys-.*\.txt$/));
    my $load_size = @load_keys;
    is($queue->add(@load_keys), $load_size, 'All keys added to pending');
    %stats = ();
    {
        # We know we cannot really price (or convert to relative shortcodes)
        # in most places, so don't emit so much noise.
        $SIG{__WARN__} = sub { };
        $queue->process;
        is($queue->active_job_count, $load_size, 'All keys converted to jobs');
        my $daemon = new_ok('BOM::Pricing::PriceDaemon', [tags => ['tag:1.2.3.4']], 'Test daemon');
        my $fake_tick = Test::MockObject->new();
        $fake_tick->mock('epoch',  sub { time });
        $fake_tick->mock('quote',  sub { 100 });
        $fake_tick->mock('symbol', sub { 'FAKE' });
        my $fake_underlying = Test::MockObject->new();
        $fake_underlying->mock('symbol',    sub { 'FAKE' });
        $fake_underlying->mock('spot_tick', sub { $fake_tick });
        no strict 'refs';
        local *{"BOM::Pricing::PriceDaemon::_get_underlying_or_log"} = sub { $fake_underlying };
        # Simulate paired processes.
        # Actually forking them might cause a lot of heartache in various testing environments
        my $iters = 5;
        # We run the queue at a slower rate than in reality.
        # Otherwise it will spend most of its time sleeping
        # to the start of the pricing interval, pausing the
        # processing. Luckily the `sleep` is in the sames
        # place as we are alarming. (Interaciton unspecified)
        alarm(1.143, 3.912);
        local $SIG{ALRM} = sub {
            state $i = 0;
            my $actives = $queue->active_job_count;
            if ($actives and $i < $iters) {
                # This can fail because we signaled while
                # awaiting replies.  We can just try again later
                try {
                    $queue->process;
                    $i++;
                    note sprintf('Iteration: %d, Active: %d', $i, $queue->active_job_count);
                };
            } else {
                alarm(0);
                $daemon->stop;
            }
        };
        # This is an MVP configuration, can be exxpanded to improve realism as needed
        $daemon->run(
            queues       => ['pricer_jobs'],
            ip           => '1.2.3.4',
            fork_index   => 0,
            pid          => $$,
            queue_obj    => $queue,
            wait_timeout => 1,
        );
    }
    my $active = $queue->active_job_count;
    cmp_ok($active, '<=', $load_size - 100, 'Consumed at least 100 queue items');
    my @index_channels = sort { $a cmp $b } ($queue->channels_from_index);
    note 'We do not want an explicit test here, because we might be able to actually price';
    note 'Active: ' . $active;
    note 'Pending: ' . scalar(@index_channels);
    note np(%stats);

    my @keys_channels = sort { $a cmp $b } ($queue->channels_from_keys);
    eq_or_diff(\@index_channels, \@keys_channels, 'Index and keyspace are in sync');
    note 'The below should be implied by the above, but we pick an example:';
    my $j   = int(rand(scalar @index_channels));
    my $ani = $index_channels[$j];
    my $ak  = $keys_channels[$j];
    cmp_ok($ani, 'eq', $ak, 'Keys in the same positions are equivalent');
    my $efck = \&BOM::Pricing::v3::Utility::extract_from_channel_key;
    my ($ip, $kp) = map { [BOM::Pricing::v3::Utility::extract_from_channel_key($_)] } ($ani, $ak);
    eq_or_diff($ip, $kp, '... as are the parameters extracted therefrom');
    cmp_ok($sfp->($ip->[0]), 'eq', $sfp->($kp->[0]), '... and the numbers produced from scoring.');
};

done_testing;
