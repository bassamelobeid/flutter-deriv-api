use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::Trap;

use BOM::Platform::Runtime;
use Cache::RedisDB;
use BOM::MarketData::FeedRaw;
use BOM::Market::DataDecimate;
use File::Slurp;
use File::Temp;
use ZMQ::Constants qw(ZMQ_PUB);
use ZMQ::LibZMQ3;
use YAML::XS 0.35;
use Net::EmptyPort qw(empty_port);
use LandingCompany::Offerings qw(reinitialise_offerings);

BOM::Platform::Runtime->instance->app_config;
reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);

my $test_pid = $$;
my $dir      = File::Temp->newdir;


my $dist_port = empty_port;
my $pid = fork;
if (!$pid) {
    # child;
    my $client = BOM::MarketData::FeedRaw->new(
        feed_distributor    => "localhost:$dist_port",
        timeout             => 2,
    );
    my $success = 1;
    while($success) {
        $success = $client->iterate;
    }
    warn("exiting child/feed-decimate, not expected to dot that");
    exit(-1);
}

my $ctx = zmq_init(1) or die "Couldn't create ZMQ context: $!";
my $pub_sock = zmq_socket($ctx, ZMQ_PUB) or die "Couldn't create ZMQ socket: $!";
zmq_bind($pub_sock, "tcp://*:$dist_port") and die "Couldn't bind to $dist_port: $!";
Net::EmptyPort::wait_port($dist_port, 10);
pass "Created listening ZMQ socket";

sleep 1;

my $time = time;
my $tick = {
    epoch  => $time,
    symbol => 'frxUSDJPY',
    quote  => '108.222',
    bid    => '108.223',
    ask    => '108.224',
};
zmq_sendmsg($pub_sock, Dump($tick), 0);

# give some time for feed-client to process the tick
sleep(1);
ok(!zmq_close($pub_sock));
sleep(1);

my $cache = BOM::Market::DataDecimate->new();

my $rtick = $cache->_get_num_data_from_cache({
        symbol => 'frxUSDJPY',
        num    => 1,
        end_epoch => $time,
    });

eq_or_diff $rtick->[0],
    {
    epoch  => $time,
    symbol => 'frxUSDJPY',
    quote  => '108.222',
    bid    => '108.223',
    ask    => '108.224',
    count  => 1,
    },
    "cache was updated";

kill 9 => $pid;

done_testing;
