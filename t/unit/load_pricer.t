use strict;
use warnings;
use feature qw(state);
use Test::More;
use Test::MockModule;
use YAML::XS;
use BOM::Test::LoadTest::Pricer qw(dd_memory);

my $mocked_loadtest = Test::MockModule->new('BOM::Test::LoadTest::Pricer');
my @dd_data;
$mocked_loadtest->mock('stats_gauge', sub {push @dd_data, \@_});
my @process_table;
my $mocked_process_table = Test::MockModule->new('Proc::ProcessTable');
$mocked_process_table->mock('table', sub{return \@process_table});
my @expected_data = Load(do{local $/; <DATA>});
sub populate_process_table {
    my $reset = shift;
    my @process_cmds = (
        'a_processor --something some arg',
        'bin/binary_rpc_redis.pl --category=general --extra args',
        'bin/binary_rpc_redis.pl --category=general --extra args',  # suppose we have 2 rpc_redis process
        'bin/binary_rpc_redis.pl --category=tick --extra args',
        'bin/price_queue.pl --arg1',
        'bin/price_daemon.pl --arg2',
        'bin/price_daemon.pl --arg2',  # 2 price_daemon to simulate 2 processes, one is another's subprocess
        'pricer_load_runner.pl --arg something',
        'proposal_sub.pl --arg something'
    );
    state $count = 10;
    if($reset){
        $count = 10;
    }
    @process_table = map {+{
        cmndline => $_,
        pid => $count++,
        ppid => 1, # in most cass, ppid is 1
        size => $count++,
        rss => $count++,
    }} @process_cmds;
    $process_table[5]{ppid} = $process_table[4]{pid}; # the second price_daemon process is the first one's subprocess
}
subtest 'general case' => sub{
    populate_process_table(1);
    @dd_data = ();
    dd_memory('market_name');
    is_deeply(\@dd_data, $expected_data[0], 'dd write correct');
    @dd_data = ();
    populate_process_table(0);
    dd_memory();
    is_deeply(\@dd_data, $expected_data[1], 'dd write correct for second');
    ok(1);
};


ok(1);
done_testing();

__DATA__

---
- - memory.rpc_redis_general.size
  - 14
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.rpc_redis_general.rss
  - 15
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.rpc_redis_general.size
  - 17
  - tags:
    - tag:idx2
    - tag:market_name
- - memory.rpc_redis_general.rss
  - 18
  - tags:
    - tag:idx2
    - tag:market_name
- - memory.rpc_redis_tick.size
  - 20
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.rpc_redis_tick.rss
  - 21
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.price_queue.size
  - 23
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.price_queue.rss
  - 24
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.price_daemon.size
  - 26
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.price_daemon.rss
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.pricer_load_runner.size
  - 32
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.pricer_load_runner.rss
  - 33
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.proposal_sub.size
  - 35
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.proposal_sub.rss
  - 36
  - tags:
    - tag:idx1
    - tag:market_name
---
- - memory.rpc_redis_general.size
  - 41
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.rpc_redis_general.size.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.rpc_redis_general.rss
  - 42
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.rpc_redis_general.rss.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.rpc_redis_general.size
  - 44
  - tags:
    - tag:idx2
    - tag:market_name
- - memory.rpc_redis_general.size.delta
  - 27
  - tags:
    - tag:idx2
    - tag:market_name
- - memory.rpc_redis_general.rss
  - 45
  - tags:
    - tag:idx2
    - tag:market_name
- - memory.rpc_redis_general.rss.delta
  - 27
  - tags:
    - tag:idx2
    - tag:market_name
- - memory.rpc_redis_tick.size
  - 47
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.rpc_redis_tick.size.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.rpc_redis_tick.rss
  - 48
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.rpc_redis_tick.rss.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.price_queue.size
  - 50
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.price_queue.size.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.price_queue.rss
  - 51
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.price_queue.rss.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.price_daemon.size
  - 53
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.price_daemon.size.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.price_daemon.rss
  - 54
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.price_daemon.rss.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.pricer_load_runner.size
  - 59
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.pricer_load_runner.size.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.pricer_load_runner.rss
  - 60
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.pricer_load_runner.rss.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.proposal_sub.size
  - 62
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.proposal_sub.size.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.proposal_sub.rss
  - 63
  - tags:
    - tag:idx1
    - tag:market_name
- - memory.proposal_sub.rss.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
