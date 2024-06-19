use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::MockObject;
use Test::Exception;
use Path::Tiny;
use Future::AsyncAwait;
use Log::Any::Test;
use Log::Any qw($log);

use_ok "BOM::Database::Script::CircuitBreaker";
my $breaker;
subtest "init" => sub {
    my $tmp_config = Path::Tiny->tempfile;
    $tmp_config->spew(<<'EOF');
[databases]
authdb = dbname=auth port=5435 host=127.0.0.1 user=write password=Abcdefg pool_mode=transaction
authdb2 = dbname=auth port=5435 host=127.0.0.1 user=write password=Abcdefg pool_mode=transaction
db3 = dbname=some port=5435 host=127.0.0.1 user=write password=Abcdefg pool_mode=transaction
EOF
    lives_ok {
        $breaker = BOM::Database::Script::CircuitBreaker->new(
            bouncer_uri => undef,
            cfg_file    => $tmp_config
        )
    }
    "run init ok";
    is_deeply(
        $breaker->{cfg},
        {
            'postgresql://write:Abcdefg@127.0.0.1:5435/some' => ['db3'],
            'postgresql://write:Abcdefg@127.0.0.1:5435/auth' => ['authdb', 'authdb2']
        },
        "parse cfg file ok"
    );
};

subtest operation => sub {
    my $mocked_loop = Test::MockModule->new('IO::Async::Loop');
    $mocked_loop->mock('run_process', sub { shift; return Future->done(+{@_}) });
    my $result = $breaker->operation(['RESUME "^"', 'ENABLE "^"'], [qw(db1 db2)])->get;
    is_deeply(
        $result,
        {
            'capture' => ['exitcode', 'stderr'],
            'command' => ['psql',     '-qXAt', '-v', 'ON_ERROR_STOP=1', 'postgresql://postgres@:6432/pgbouncer'],
            'stdin'   => qq{RESUME "db1";\nENABLE "db1";\nRESUME "db2";\nENABLE "db2";\n}
        },
        'operation result ok'
    );
};

subtest suspend => sub {
    my $mocked_breaker = Test::MockModule->new('BOM::Database::Script::CircuitBreaker');
    my $operation_args;
    my $operation_result = [1, 'Error happen'];
    $mocked_breaker->mock('operation', sub { shift; $operation_args = [@_]; return Future->done($operation_result->@*) });
    my $stats_args;
    $mocked_breaker->mock('stats_inc', sub { $stats_args = [@_] });
    $log->clear;
    lives_ok { $breaker->suspend([qw(db1 db2)]) } "calling suspend ok";
    is_deeply($operation_args, [['DISABLE "^"', 'KILL "^"'], ['db1', 'db2']], "operation function called with right args");
    ok(!$stats_args, "stats_inc not called");
    $log->contains_ok('failed to suspend');
    $operation_result = [0, ''];
    $operation_args   = undef;
    lives_ok { $breaker->suspend([qw(db1 db2)]) } "calling suspend ok";
    is_deeply($operation_args, [['DISABLE "^"', 'KILL "^"'], ['db1', 'db2']], "operation function called with right args");
    ok($stats_args, "stats_inc is called");
    $log->contains_ok('suspended');

};

subtest resume => sub {
    my $mocked_breaker = Test::MockModule->new('BOM::Database::Script::CircuitBreaker');
    my $operation_args;
    # test error
    my $operation_result = [1, 'Error happen'];
    $mocked_breaker->mock('operation', sub { shift; $operation_args = [@_]; return Future->done($operation_result->@*) });
    my $stats_args;
    $mocked_breaker->mock('stats_inc', sub { push @$stats_args, [@_] });
    $log->clear;
    lives_ok { $breaker->resume([qw(db1 db2)]) } "calling resume ok";
    is_deeply($operation_args, [['RESUME "^"', 'ENABLE "^"'], ['db1', 'db2']], "operation function called with right args");
    $log->contains_ok('failed to resume');
    ok(!$stats_args, "stats_inc not called");

    # test 'is not paused' error
    $operation_result = [1, 'is not paused'];
    $log->clear;
    lives_ok { $breaker->resume([qw(db1 db2)]) } "calling resume ok";
    $log->empty_ok;

    # no error
    $operation_result = [0, ''];
    $operation_args   = undef;
    $log->clear;
    lives_ok { $breaker->resume([qw(db1 db2)]) } "calling resume ok";
    is_deeply($operation_args, [['RESUME "^"', 'ENABLE "^"'], ['db1', 'db2']], "operation function called with right args");
    is_deeply($stats_args, [['circuitbreaker.resume.db1'], ['circuitbreaker.resume.db2']], "stats_inc is called");
    $log->contains_ok('resumed');

};

subtest do_check => sub {
    my $mocked_breaker = Test::MockModule->new('BOM::Database::Script::CircuitBreaker');
    my ($status_result, @resume_args, @suspend_args, $resume_result, $suspend_result, @stats_inc_args, $result, @function_args);
    $breaker->{function} = Test::MockObject->new;
    $breaker->{function}->mock('call', sub { shift; push @function_args, [@_]; return $status_result });
    $mocked_breaker->mock('resume',    sub { shift; push @resume_args,  [@_]; return $resume_result });
    $mocked_breaker->mock('suspend',   sub { shift; push @suspend_args, [@_]; return $suspend_result });
    $mocked_breaker->mock('stats_inc', sub { push @stats_inc_args, [@_] });

    # At first, db is offline, first time checking db ok
    $log->clear;
    $status_result = Future->done(1);
    $resume_result = Future->done(1);
    lives_ok { $result = $breaker->do_check('db_uri', ['db1', 'db2'], 0)->get } "at first db offline, check and ok";
    ok(!@stats_inc_args, 'no stats_inc called');
    is(scalar($log->msgs->@*), 1, "only one log message");
    $log->contains_ok('SUCCESS');
    is($result, 1, "db is online");
    is_deeply(\@function_args, [[args => ['db_uri']]], 'function called only once with right args');
    is_deeply(\@resume_args,   [[['db1', 'db2']]],     'resume is called');

    # at first is offline, it will try 1 time even check failed.
    $log->clear;
    $status_result  = Future->fail(1);
    $resume_result  = Future->done(1);
    @stats_inc_args = ();
    @function_args  = ();
    lives_ok { $result = $breaker->do_check('db_uri', ['db1', 'db2'], 0)->get } "at first db offline, check and fail";
    is_deeply(\@stats_inc_args, [['circuitbreaker.failure.db1'], ['circuitbreaker.failure.db2']], 'stats_inc called');
    is_deeply(\@suspend_args,   [],                                                               'suspend is called');
    is(scalar($log->msgs->@*), 1, "only one log message");
    $log->contains_ok('FAIL', 'one debug message');
    is($result, 0, "db is offline");
    is_deeply(\@function_args, [[args => ['db_uri']]], 'function called only once with right args');

    # at first is online, it will at most 3 times. If all failed, then suspend.
    $log->clear;
    $status_result  = Future->fail(1);
    $suspend_result = Future->done(1);
    @stats_inc_args = ();
    @suspend_args   = ();
    @function_args  = ();
    lives_ok { $result = $breaker->do_check('db_uri', ['db1', 'db2'], 1)->get } "at first db online, check and fail";
    is_deeply(
        \@stats_inc_args,
        [
            ['circuitbreaker.failure.db1'], ['circuitbreaker.failure.db2'], ['circuitbreaker.failure.db1'], ['circuitbreaker.failure.db2'],
            ['circuitbreaker.failure.db1'], ['circuitbreaker.failure.db2']
        ],
        'stats_inc called'
    );
    is_deeply(\@suspend_args, [[['db1', 'db2']]], 'suspend is called');
    is(scalar($log->msgs->@*), 1, "1 log message");
    $log->contains_ok('FAIL', 'one debug message');
    is($result, 0, "db is offline");
    is_deeply(\@function_args, [[args => ['db_uri']], [args => ['db_uri']], [args => ['db_uri']]], 'function called only once with right args');

    # at first is offline, it will try at most 3 times. If all failed, then suspend
    $log->clear;
    $status_result  = Future->fail(1);
    $suspend_result = Future->done(1);
    @stats_inc_args = ();
    @suspend_args   = ();
    @function_args  = ();
    lives_ok { $result = $breaker->do_check('db_uri', ['db1', 'db2'], undef)->get } "at first db unknown, check and fail";
    is_deeply(
        \@stats_inc_args,
        [
            ['circuitbreaker.failure.db1'], ['circuitbreaker.failure.db2'], ['circuitbreaker.failure.db1'], ['circuitbreaker.failure.db2'],
            ['circuitbreaker.failure.db1'], ['circuitbreaker.failure.db2']
        ],
        'stats_inc called'
    );
    is_deeply(\@suspend_args, [[['db1', 'db2']]], 'suspend is called');
    is(scalar($log->msgs->@*), 1, "1 log message");
    $log->contains_ok('FAIL', 'one debug message');
    is($result, 0, "db is offline");
    is_deeply(\@function_args, [[args => ['db_uri']], [args => ['db_uri']], [args => ['db_uri']]], 'function called only once with right args');

    # At first db status is unknown, first time checking db ok
    $log->clear;
    $status_result  = Future->done(1);
    $resume_result  = Future->done(1);
    @stats_inc_args = ();
    @function_args  = ();
    @resume_args    = ();
    lives_ok { $result = $breaker->do_check('db_uri', ['db1', 'db2'], undef)->get } "at first db offline, check and ok";
    ok(!@stats_inc_args, 'no stats_inc called');
    is(scalar($log->msgs->@*), 1, "only one log message");
    $log->contains_ok('SUCCESS');
    is($result, 1, "db is online");
    is_deeply(\@function_args, [[args => ['db_uri']]], 'function called only once with right args');
    is_deeply(\@resume_args,   [[['db1', 'db2']]],     'resume is called');

};

done_testing();
