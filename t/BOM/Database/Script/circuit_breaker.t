use strict;
use warnings;
use Test::More;
use Path::Tiny;
use Test::MockModule;
use Test::Exception;
use IO::Async::Loop;

use_ok('BOM::Database::Script::CircuitBreaker');

subtest 'test check db server function' => sub {
    my %test_env = init_test();
    my $breaker  = $test_env{breaker};
    isa_ok($breaker->{function}, 'IO::Async::Function');
    my $loop     = IO::Async::Loop->new;
    my $listener = $loop->listen(
        service   => 0,
        socktype  => 'stream',
        on_stream => sub {
            my ($stream) = @_;
            # We don't want to read, and we don't want to write - just sit
            # there passively after accepting the connection
            $stream->configure(on_read => sub { 0 });
            $loop->add($stream);
        })->get;
    my $mock_dbi = $test_env{mock_dbi};
    $mock_dbi->unmock_all;
    my $port = $listener->read_handle->sockport;
    $breaker->{function}->restart;
    my $time = time;
    throws_ok { $breaker->{function}->call(args => ["postgresql://user:password\@127.0.0.1:$port/auth"])->get } qr/Timeout/;
    ok(time - $time < 2, 'Timeout is less than 2 seconds');
    $loop->remove($listener);

    $mock_dbi->mock('connect', sub { return 'DBI'; });
    $mock_dbi->mock('do',      sub { sleep 1 });
    $breaker->{function}->restart;
    throws_ok { $breaker->{function}->call(args => ['postgresql://user:password@127.0.0.1:1234/auth'])->get } qr/Timeout/;
    $breaker->{function}->restart;
};

subtest 'parse cfg' => sub {
    my %test_env = init_test();
    is_deeply(
        $test_env{breaker}{cfg},
        {
            'postgresql://write:password@127.0.0.1:5451/db1' => ['test_db1', 'test_db1_alias'],
            'postgresql://write:password@127.0.0.1:5451/db2' => ['test_db2'],
            'postgresql://write:password@127.0.0.1:5452/db3' => ['test_db3']
        },
        "parse cfg file"
    );
};

subtest 'max workers' => sub {
    my %test_env = init_test();
    my $breaker  = $test_env{breaker};
    is($breaker->{function}->{max_workers}, 3, "max_workers should equal to the number of db servers");
};

subtest 'opertion' => sub {
    my %test_env  = init_test();
    my $breaker   = $test_env{breaker};
    my $mock_loop = Test::MockModule->new('IO::Async::Loop');
    $mock_loop->mock('run_process', sub { shift; return Future->done([@_]); });
    is_deeply(
        $breaker->operation(['DISABLE "^"', 'KILL "^"'], [qw(db1 db2)])->get,
        [
            'command',
            [
                'psql',
                '-qXAt',
                '-v',
                'ON_ERROR_STOP=1',
                'postgresql://postgres@:6432/pgbouncer'
            ],
            'stdin',
            'DISABLE "db1";
KILL "db1";
DISABLE "db2";
KILL "db2";
',
            'capture',
            ['exitcode', 'stderr']
        ],
        "operation will call run_process"
    );
};

subtest do_check => sub {
    my %test_env      = init_test();
    my $mock_breaker  = Test::MockModule->new('BOM::Database::Script::CircuitBreaker');
    my $resume_count  = 0;
    my $suspend_count = 0;
    $mock_breaker->mock('resume',  sub { $resume_count++;  return Future->done });
    $mock_breaker->mock('suspend', sub { $suspend_count++; return Future->done });
    my $breaker = $test_env{breaker};
    $breaker->{function}->{max_workers} = 1;
    my $url = 'postgresql://write:password@127.0.0.1:5451/db2';
    ok($breaker->do_check($url, ['db2'])->get, 'do_check will return true if db is ok');
    is($resume_count,  1, "resume is called");
    is($suspend_count, 0, "suspend is not called");
    $_->kill(15) for (values $breaker->{function}{workers}->%*);
    $breaker->{function}->stop;
    (delete $breaker->{function_call}{$_})->cancel for keys $breaker->{function_call}->%*;

    my $mock_function = Test::MockModule->new('IO::Async::Function');
    my $call_count    = 0;
    $resume_count  = 0;
    $suspend_count = 0;
    $mock_function->mock('call', sub { $call_count++; return Future->fail('error') });
    $breaker->{function_call} = {};
    my $last_status = undef;
    is($breaker->do_check($url, ['db2'], $last_status)->get, 0, 'do_check will return 0 if db is not ok');
    is($resume_count,                                        0, "resume is not called");
    is($suspend_count,                                       1, "suspend is called");
    is($call_count, 3, 'function is called 3 times to retry test if the begin status is undef and db is not ok');

    $call_count               = 0;
    $last_status              = 1;
    $resume_count             = 0;
    $suspend_count            = 0;
    $breaker->{function_call} = {};
    is($breaker->do_check($url, ['db2'], $last_status)->get, 0, 'do_check will return 0 if db is not ok');
    is($resume_count,                                        0, "resume is not called");
    is($suspend_count,                                       1, "suspend is called");
    is($call_count, 3, 'function is called 3 times to retry test if the begin status is online and now db is not ok');

    $call_count               = 0;
    $last_status              = 0;
    $resume_count             = 0;
    $suspend_count            = 0;
    $breaker->{function_call} = {};
    is($breaker->do_check($url, ['db2'], $last_status)->get, 0, 'do_check will return 0 if db is not ok');
    is($call_count,    1, 'function is called 1 time, no retry test if the begin status is offline and now db is not ok');
    is($resume_count,  0, "resume is not called");
    is($suspend_count, 0, "suspend is not called");

    # database ok
    $mock_function->mock('call', sub { $call_count++; return Future->done });
    for $last_status (undef, 0, 1) {
        $resume_count             = 0;
        $suspend_count            = 0;
        $call_count               = 0;
        $breaker->{function_call} = {};
        is($breaker->do_check($url, ['db2'], $last_status)->get, 1, 'do_check will return 1 if db is ok');
        is($call_count,                                          1, 'function is called 1 time aaa');
        if (!$last_status) {
            is($resume_count, 1, "resume is called");
        } else {
            is($resume_count, 0, "resume is not called");
        }
        is($suspend_count, 0, "suspend is not called");
    }
};

subtest restart => sub {
    my %test_env = init_test();
    my $breaker  = $test_env{breaker};
    my $cfg_file = $test_env{cfg_file};
    $cfg_file->spew(<<~'EOF');
  test_db1_alias = dbname=db1 port=5451 host=127.0.0.1 user=write password=password pool_mode=transaction
  EOF

    $breaker->restart();
    is_deeply(
        $test_env{breaker}{cfg},
        {
            'postgresql://write:password@127.0.0.1:5451/db1' => ['test_db1_alias'],
        },
        "cfg is changed"
    );
    my $mock_breaker   = Test::MockModule->new('BOM::Database::Script::CircuitBreaker');
    my $do_check_count = 0;
    $mock_breaker->mock('do_check', sub { $do_check_count++; return Future->done(1) });
    is($do_check_count, 0, "while loop not running");
};
# TODO test workers number
sub init_test {
    my %test_env;
    $test_env{cfg_file} = Path::Tiny->tempfile();
    $test_env{cfg_file}->spew(<<~'EOF');
  test_db1 = dbname=db1 port=5451 host=127.0.0.1 user=write password=password pool_mode=session
  test_db1_alias = dbname=db1 port=5451 host=127.0.0.1 user=write password=password pool_mode=transaction
  test_db2 = dbname=db2 port=5451 host=127.0.0.1 user=write password=password pool_mode=transaction
  test_db3 = dbname=db3 port=5452 host=127.0.0.1 user=write password=password pool_mode=transaction
  test_db4_test = dbname=db4 port=5453 host=127.0.0.1 user=write password=password pool_mode=transaction
  EOF
    my $mock_dbi = Test::MockModule->new('DBI');
    $mock_dbi->mock('connect', sub { return 'DBI'; });
    $mock_dbi->mock('do',      sub { return 1 });
    $test_env{breaker} = BOM::Database::Script::CircuitBreaker->new(
        cfg_file       => $test_env{cfg_file},
        delay_interval => 0.1,
        check_interval => 0.1
    );
    $test_env{mock_dbi} = $mock_dbi;
    return %test_env;
}

done_testing();
