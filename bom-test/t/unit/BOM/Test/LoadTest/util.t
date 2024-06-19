use strict;
use warnings;
use feature qw(state);
use Test::More;
use Test::MockModule;
use Test::MockTime qw(set_relative_time restore_time);
use YAML::XS;
use BOM::Test::LoadTest::Util qw(dd_memory_and_time);

my $mocked_util = Test::MockModule->new('BOM::Test::LoadTest::Util');
my @dd_data;
$mocked_util->mock('stats_gauge', sub { push @dd_data, \@_ });
my @process_table;
subtest 'dd_memory' => sub {
    my $mocked_process_table = Test::MockModule->new('Proc::ProcessTable');
    $mocked_process_table->mock('table', sub { return \@process_table });
    my @test_data = Load(do { local $/; <DATA> });
    @process_table = $test_data[0]->@*;
    @dd_data       = ();
    BOM::Test::LoadTest::Util::dd_memory('market_name');
    is_deeply(\@dd_data, $test_data[2], 'dd write correct');
    @dd_data       = ();
    @process_table = $test_data[1]->@*;
    BOM::Test::LoadTest::Util::dd_memory();
    is_deeply(\@dd_data, $test_data[3], 'dd write correct for second');
};

subtest 'dd_time' => sub {
    my $time_interval = 100;
    set_relative_time(-$time_interval);
    @dd_data = ();
    BOM::Test::LoadTest::Util::dd_time('market_name');
    is(scalar @dd_data, 0, "no datadog data at the first call");
    restore_time();
    BOM::Test::LoadTest::Util::dd_time();
    is_deeply(\@dd_data, [['qaloadtest.time.market_name', $time_interval]], 'dd metric correct');
};

done_testing();

__DATA__
---
- cmndline: a_processor --something some arg
  pid: 10
  ppid: 1
  rss: 12
  size: 11
- cmndline: bin/binary_rpc_redis.pl --category=general --extra args
  pid: 13
  ppid: 1
  rss: 15
  size: 14
- cmndline: bin/binary_rpc_redis.pl --category=general --extra args
  pid: 16
  ppid: 1
  rss: 18
  size: 17
- cmndline: bin/binary_rpc_redis.pl --category=tick --extra args
  pid: 19
  ppid: 1
  rss: 21
  size: 20
- cmndline: bin/price_queue.pl --arg1
  pid: 22
  ppid: 1
  rss: 24
  size: 23
- cmndline: bin/price_daemon.pl --arg2
  pid: 25
  ppid: 22
  rss: 27
  size: 26
- cmndline: bin/price_daemon.pl --arg2
  pid: 28
  ppid: 1
  rss: 30
  size: 29
- cmndline: pricer_load_runner.pl --arg something
  pid: 31
  ppid: 1
  rss: 33
  size: 32
- cmndline: proposal_sub.pl --arg something
  pid: 34
  ppid: 1
  rss: 36
  size: 35
---
- cmndline: a_processor --something some arg
  pid: 37
  ppid: 1
  rss: 39
  size: 38
- cmndline: bin/binary_rpc_redis.pl --category=general --extra args
  pid: 40
  ppid: 1
  rss: 42
  size: 41
- cmndline: bin/binary_rpc_redis.pl --category=general --extra args
  pid: 43
  ppid: 1
  rss: 45
  size: 44
- cmndline: bin/binary_rpc_redis.pl --category=tick --extra args
  pid: 46
  ppid: 1
  rss: 48
  size: 47
- cmndline: bin/price_queue.pl --arg1
  pid: 49
  ppid: 1
  rss: 51
  size: 50
- cmndline: bin/price_daemon.pl --arg2
  pid: 52
  ppid: 49
  rss: 54
  size: 53
- cmndline: bin/price_daemon.pl --arg2
  pid: 55
  ppid: 1
  rss: 57
  size: 56
- cmndline: pricer_load_runner.pl --arg something
  pid: 58
  ppid: 1
  rss: 60
  size: 59
- cmndline: proposal_sub.pl --arg something
  pid: 61
  ppid: 1
  rss: 63
  size: 62

---
- - qaloadtest.memory.rpc_redis_general.size
  - 14
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.rpc_redis_general.rss
  - 15
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.rpc_redis_general.size
  - 17
  - tags:
    - tag:idx2
    - tag:market_name
- - qaloadtest.memory.rpc_redis_general.rss
  - 18
  - tags:
    - tag:idx2
    - tag:market_name
- - qaloadtest.memory.rpc_redis_tick.size
  - 20
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.rpc_redis_tick.rss
  - 21
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.price_queue.size
  - 23
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.price_queue.rss
  - 24
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.price_daemon.size
  - 26
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.price_daemon.rss
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.pricer_load_runner.size
  - 32
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.pricer_load_runner.rss
  - 33
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.proposal_sub.size
  - 35
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.proposal_sub.rss
  - 36
  - tags:
    - tag:idx1
    - tag:market_name
---
- - qaloadtest.memory.rpc_redis_general.size
  - 41
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.rpc_redis_general.size.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.rpc_redis_general.rss
  - 42
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.rpc_redis_general.rss.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.rpc_redis_general.size
  - 44
  - tags:
    - tag:idx2
    - tag:market_name
- - qaloadtest.memory.rpc_redis_general.size.delta
  - 27
  - tags:
    - tag:idx2
    - tag:market_name
- - qaloadtest.memory.rpc_redis_general.rss
  - 45
  - tags:
    - tag:idx2
    - tag:market_name
- - qaloadtest.memory.rpc_redis_general.rss.delta
  - 27
  - tags:
    - tag:idx2
    - tag:market_name
- - qaloadtest.memory.rpc_redis_tick.size
  - 47
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.rpc_redis_tick.size.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.rpc_redis_tick.rss
  - 48
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.rpc_redis_tick.rss.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.price_queue.size
  - 50
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.price_queue.size.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.price_queue.rss
  - 51
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.price_queue.rss.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.price_daemon.size
  - 53
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.price_daemon.size.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.price_daemon.rss
  - 54
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.price_daemon.rss.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.pricer_load_runner.size
  - 59
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.pricer_load_runner.size.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.pricer_load_runner.rss
  - 60
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.pricer_load_runner.rss.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.proposal_sub.size
  - 62
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.proposal_sub.size.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.proposal_sub.rss
  - 63
  - tags:
    - tag:idx1
    - tag:market_name
- - qaloadtest.memory.proposal_sub.rss.delta
  - 27
  - tags:
    - tag:idx1
    - tag:market_name
