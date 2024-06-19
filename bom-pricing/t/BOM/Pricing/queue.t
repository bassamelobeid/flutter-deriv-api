use Test::Most;
use Test::Warnings    qw(warnings);
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
my $redis_feed   = RedisDB->new(YAML::XS::LoadFile('/etc/rmg/redis-feed.yml')->{master_read}->%*);

my $loop  = IO::Async::Loop->new;
my $queue = new_ok('BOM::Pricing::Queue', [internal_ip => '1.2.3.4'], 'New BOM::Pricing::Queue processor');
$loop->add($queue);

# Sample pricer jobs
my @keys = (
    q{PRICER_ARGS::["amount",1000,"basis","payout","contract_type","PUT","country_code","ph","currency","AUD","duration",3,"duration_unit","m","landing_company",null,"price_daemon_cmd","price","product_type","basic","proposal",1,"skips_price_validation",1,"subscribe",1,"symbol","frxAUDJPY"]},
    q{PRICER_ARGS::["amount",1000,"basis","payout","contract_type","CALL","country_code","ph","currency","AUD","duration",3,"duration_unit","m","landing_company",null,"price_daemon_cmd","price","product_type","basic","proposal",1,"skips_price_validation",1,"subscribe",1,"symbol","frxAUDJPY"]},
    q{PRICER_ARGS::["contract_id",123,"landing_company","svg","price_daemon_cmd","bid"]},
    q{PRICER_ARGS::["amount",1000,"basis","payout","contract_type","PUT","country_code","ph","currency","EUR","duration",3,"duration_unit","m","landing_company",null,"price_daemon_cmd","price","product_type","basic","proposal",1,"skips_price_validation",1,"subscribe",1,"symbol","frxEURUSD"]},
    q{PRICER_ARGS::["amount",1000,"basis","payout","contract_type","CALL","country_code","ph","currency","EUR","duration",3,"duration_unit","m","landing_company",null,"price_daemon_cmd","price","product_type","basic","proposal",1,"skips_price_validation",1,"subscribe",1,"symbol","frxEURUSD"]},
    q{PRICER_ARGS::["contract_id",124,"landing_company","svg","price_daemon_cmd","bid"]},
    q{PRICER_ARGS::["amount","21","basis","stake","contract_type","ACCU","currency","USD","duration_unit","s","growth_rate","0.03","landing_company","virtual","price_daemon_cmd","price","product_type","basic","proposal","1","skips_price_validation","1","subscribe","1","symbol","1HZ75V"]},
);

my @contract_params = ([
        q{POC_PARAMETERS::123::svg},
        q{["short_code","PUT_FRXAUDJPY_19.23_1583120649_1583120949_S0P_0","contract_id","123","currency","USD","is_sold","0","landing_company","svg","price_daemon_cmd","bid","sell_time",null]}
    ],
    [
        q{POC_PARAMETERS::124::svg},
        q{["short_code","PUT_FRXEURUSD_19.23_1583120649_1583120949_S0P_0","contract_id","124","currency","USD","is_sold","0","landing_company","svg","price_daemon_cmd","bid","sell_time",null]}
    ],
);
$redis_shared->set($_->[0] => $_->[1]) for @contract_params;

subtest 'normal flow' => sub {

    $redis->set($_ => 1) for @keys;

    $queue->update_list_of_contracts->get;
    $queue->process('frxEURUSD')->get;

    is($redis->llen('pricer_jobs'), 3,                                'frxEURUSD keys added to pricer_jobs queue, but not frxAUDJPY');
    is((keys %tags)[0],             "tag:@{[ $queue->internal_ip ]}", 'internal ip recorded as tag');

    like $redis->lrange('pricer_jobs', -1, -1)->[0], qr/"contract_id"/, 'bid contract is the first to rpop for being processed';
    $queue->process('frxAUDJPY')->get;
    is($redis->llen('pricer_jobs'), 6, 'now frxAUDJPY keys were also added');

    is($redis->llen('pricer_jobs_p0'), 0, 'no priority pricer jobs so far');
    $queue->process('1HZ75V')->get;
    is($redis->llen('pricer_jobs_p0'), 1, 'priority pricer job for ACCU contract');

    $queue->stats->get;
    is($stats{'pricer_daemon.queue.overflow'},    0, 'zero overflow reported in statd');
    is($stats{'pricer_daemon.queue.overflow_p0'}, 0, 'zero overflow reported in statd');
    is($stats{'pricer_daemon.queue.size'},        7, '7 keys were queued');
};

subtest 'overloaded daemon' => sub {
    # kill the subscriptions or they will be added again
    $redis->del($_) for @keys;

    $queue->stats->get;

    is($stats{'pricer_daemon.queue.overflow'}, @keys, 'overflow correctly reported in statsd');
    is($redis->llen('pricer_jobs'),            0,     'non-processed jobs have been dequeued');
};

subtest 'symbol_for_contract' => sub {
    is($queue->symbol_for_contract('123::svg')->get, 'frxAUDJPY', 'correct symbol for 123::svg');
};

subtest 'parameters_for_contract' => sub {
    throws_ok {
        $queue->parameters_for_contract('1::test')->get
    }
    qr/Contract parameters/, 'Contract parameters not found';
};

done_testing;
