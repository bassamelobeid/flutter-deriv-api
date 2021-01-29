#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;

use BOM::MT5::Utility::CircuitBreaker;

my $mock_redis            = Test::MockModule->new('RedisDB');
my $mock_circuit          = Test::MockModule->new('BOM::MT5::Utility::CircuitBreaker');
my $failure_count_key     = 'system.mt5.server-type_server-code.connection_fail_count';
my $last_failure_time_key = 'system.mt5.server-type_server-code.last_failure_time';
my $testing_key           = 'system.mt5.server-type_server-code.connection_test';

subtest 'Circuit status is closed at the beginning' => sub {

    $mock_redis->mock(
        get => sub {
            my (undef, $redis_key) = @_;
            return 0 if $redis_key eq $failure_count_key || $redis_key eq $last_failure_time_key;
            return 1;
        });

    my $circuit_breaker = BOM::MT5::Utility::CircuitBreaker->new(
        server_type => 'server-type',
        server_code => 'server-code'
    );
    ok $circuit_breaker->_is_circuit_closed(), 'Circuit status is closed';
    ok !$circuit_breaker->_is_circuit_open(),      'Circuit status is not open';
    ok !$circuit_breaker->_is_circuit_half_open(), 'Circuit status is not half open';
    $mock_redis->unmock_all();

};

subtest 'Circuit status is open' => sub {

    $mock_redis->mock(
        get => sub {
            my (undef, $redis_key) = @_;
            return 30   if $redis_key eq $failure_count_key;
            return time if $redis_key eq $last_failure_time_key;
            return undef;
        });

    my $circuit_breaker = BOM::MT5::Utility::CircuitBreaker->new(
        server_type => 'server-type',
        server_code => 'server-code'
    );
    ok !$circuit_breaker->_is_circuit_closed(), 'Circuit status is not closed';
    ok $circuit_breaker->_is_circuit_open(), 'Circuit status is open';
    ok !$circuit_breaker->_is_circuit_half_open(), 'Circuit status is not half open';
    $mock_redis->unmock_all();
};

subtest 'Circuit status is half open' => sub {

    $mock_redis->mock(
        get => sub {
            my (undef, $redis_key) = @_;
            return 30 if $redis_key eq $failure_count_key;
            return 0  if $redis_key eq $last_failure_time_key;
            return undef;
        });

    my $circuit_breaker = BOM::MT5::Utility::CircuitBreaker->new(
        server_type => 'server-type',
        server_code => 'server-code'
    );
    ok !$circuit_breaker->_is_circuit_closed(), 'Circuit status is not closed';
    ok !$circuit_breaker->_is_circuit_open(),   'Circuit status is not open';
    ok $circuit_breaker->_is_circuit_half_open(), 'Circuit status is half open';
    $mock_redis->unmock_all();
};

subtest 'Reset circuit' => sub {

    my $result;
    $mock_redis->mock(
        del => sub {
            my (undef, @redis_keys) = @_;
            $result->{$_} = 1 for @redis_keys;
        });

    my $expected_result = {
        $failure_count_key     => 1,
        $last_failure_time_key => 1,
        $testing_key           => 1,
    };

    my $circuit_breaker = BOM::MT5::Utility::CircuitBreaker->new(
        server_type => 'server-type',
        server_code => 'server-code'
    );
    $circuit_breaker->circuit_reset();
    is_deeply $result, $expected_result, 'Reset circuit correctly';
    $mock_redis->unmock_all();

};

subtest 'Record failure' => sub {

    my $result;
    $mock_redis->mock(
        set => sub {
            my (undef, $redis_key, $redis_value) = @_;
            $result->{$redis_key} = $redis_value;
        },
        incr => sub {
            my (undef, $redis_key) = @_;
            $result->{$redis_key}++;
        });

    my $expected_result = {
        $failure_count_key     => 1,
        $last_failure_time_key => time
    };

    my $circuit_breaker = BOM::MT5::Utility::CircuitBreaker->new(
        server_type => 'server-type',
        server_code => 'server-code'
    );
    $circuit_breaker->record_failure();
    is_deeply $result, $expected_result, 'Record failure correctly';
    $mock_redis->unmock_all();

};

subtest 'Testing mode' => sub {

    my $circuit_breaker = BOM::MT5::Utility::CircuitBreaker->new(
        server_type => 'server-type',
        server_code => 'server-code'
    );

    # Reset the circuit before testing
    $circuit_breaker->circuit_reset();

    is $circuit_breaker->_set_testing(), 1, "Set Testing sucessfully for the first time";
    is $circuit_breaker->_set_testing(), 0, "Failed to set testing when it exists already.";

    # Testing falg will be dropped when record a failure
    $circuit_breaker->record_failure();
    is $circuit_breaker->_set_testing(), 1, "Set Testing sucessfully after remove the flag";

    # Testing falg will be dropped when reset the circuit
    $circuit_breaker->circuit_reset();
    is $circuit_breaker->_set_testing(), 1, "Set Testing sucessfully";
};

subtest 'Request state' => sub {

    my $circuit_breaker = BOM::MT5::Utility::CircuitBreaker->new(
        server_type => 'server-type',
        server_code => 'server-code'
    );

    # Circuit is open
    $mock_circuit->mock(
        _is_circuit_open => sub {
            return 1;
        });

    my $expected_result = {
        allowed => 0,
        testing => 0,
    };

    is_deeply $circuit_breaker->request_state(), $expected_result, 'Requset not allowed';
    $mock_circuit->unmock_all();

    # Circuit is half-open and testing flag not exists
    $mock_circuit->mock(
        _is_circuit_open => sub {
            return 0;
        },
        _is_circuit_half_open => sub {
            return 1;
        },
        _set_testing => sub {
            return 1;
        });

    $expected_result = {
        allowed => 1,
        testing => 1,
    };

    is_deeply $circuit_breaker->request_state(), $expected_result, 'Testing request';
    $mock_circuit->unmock_all();

    # Circuit is half-open and testing flag exists
    $mock_circuit->mock(
        _is_circuit_open => sub {
            return 0;
        },
        _is_circuit_half_open => sub {
            return 1;
        },
        _set_testing => sub {
            return 0;
        });

    $expected_result = {
        allowed => 0,
        testing => 0,
    };

    is_deeply $circuit_breaker->request_state(), $expected_result, 'Testing flag exists';
    $mock_circuit->unmock_all();

    # Circuit is closed
    $mock_circuit->mock(
        _is_circuit_open => sub {
            return 0;
        },
        _is_circuit_half_open => sub {
            return 0;
        });
    $expected_result = {
        allowed => 1,
        testing => 0,
    };

    is_deeply $circuit_breaker->request_state(), $expected_result, 'Request allowed';
    $mock_circuit->unmock_all();
};

done_testing();
