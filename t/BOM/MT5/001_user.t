#!perl

use strict;
use warnings;

use Test::More;
use Test::Deep qw(cmp_deeply);
use Test::MockModule;
use Test::Fatal;

use Syntax::Keyword::Try;
use Scope::Guard qw(guard);
use Locale::Country qw(country2code);

use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::MT5::User::Async;
use BOM::User::Utility qw(parse_mt5_group);
use BOM::Config::Runtime;
use BOM::MT5::Utility::CircuitBreaker;

subtest 'MT5 Circuit Breaker' => sub {
    my $mock_server_key = Test::MockModule->new('BOM::MT5::User::Async');
    $mock_server_key->mock('get_trading_server_key', sub { 'main' });

    my $timeout_return = {
        error => 'ConnectionTimeout',
        code  => 'ConnectionTimeout'
    };

    my $blocked_return = {
        error => undef,
        code  => 'NoConnection'
    };

    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');
    my $details = {group => 'real//svg_financial'};

    my $circuit_breaker = BOM::MT5::Utility::CircuitBreaker->new(
        server_type => 'real',
        server_code => 'main'
    );

    # reset the circuit status before start testing
    $circuit_breaker->circuit_reset();

    # 1st Circuit is closed, this mean the requests are allowed
    ok $circuit_breaker->_is_circuit_closed(), "Circuit is closed";

    # 2nd We will perform 21 failure request to exceed the failure threshold
    for my $i (1 .. 21) {
        try {
            # this will produce a fialed response
            BOM::MT5::User::Async::create_user($details)->get;
        } catch ($e) {
            cmp_deeply($e, $timeout_return, 'Returned timedout connection');

            my $redis_keys_value = $circuit_breaker->_get_keys_value();
            is $redis_keys_value->{failure_count}, $i, 'Fail counter count is updated';
            ok $redis_keys_value->{last_failure_time}, 'Last failure time is updated';
        }
    }

    # After exceed the failure threshold, the circuit status should be open
    ok $circuit_breaker->_is_circuit_open(), "Circuit is open";

    # The requests are not allowed when the circuit is open
    try {
        # This call will be blocked.
        BOM::MT5::User::Async::get_user('MTR1000')->get;
        is 1, 0, 'This wont be executed';
    } catch ($e) {
        cmp_deeply($e, $blocked_return, 'Call has been blocked.');
    }

    # We block the requests for 30 seconds
    # After that the circuit status will be half-open
    # We will update the last failure time to speed it.
    my $redis                 = BOM::Config::Redis::redis_mt5_user_write();
    my $last_failuer_time_key = 'system.mt5.real_main.last_failure_time';
    $redis->set($last_failuer_time_key, time - 60);
    ok $circuit_breaker->_is_circuit_half_open(), "Circuit is half-open";

    # We will consider the first request after the circuit status changed to half-open as a test request.
    # If the test request has failed, the circuit will be open and we will block the requests for the next 30 seconds.
    try {
        # This call will be timedout.
        BOM::MT5::User::Async::create_user($details)->get;
        is 1, 0, 'This wont be executed';
    } catch ($e) {
        cmp_deeply($e, $timeout_return, 'Returned timedout connection');
        my $redis_keys_value = $circuit_breaker->_get_keys_value();
        is $redis_keys_value->{failure_count}, 22, 'Fail counter count is updated';
        ok $redis_keys_value->{last_failure_time}, 'Last failure time is updated';
        ok $circuit_breaker->_is_circuit_open(), "Circuit is open";
    }

    # Update the circuit status to half open again
    $redis->set($last_failuer_time_key, time - 60);

    # Do a successful call
    ok $circuit_breaker->_is_circuit_half_open(), 'circuit status is half open';
    my $first_success = BOM::MT5::User::Async::get_user('MTR1000')->get;
    is $first_success->{login}, 'MTR1000', 'Return is correct';

    # Circuit breaker should be reset.
    ok $circuit_breaker->_is_circuit_closed(), 'circuit status is closed';

    $mock_server_key->unmock_all();
};

subtest 'parse mt5 group' => sub {
    my %dataset = (
        'real\svg' => {
            landing_company_short => 'svg',
            account_type          => 'real',
            sub_account_type      => 'std',
            server_type           => '01',
            market_type           => 'synthetic',
            currency              => 'usd',
        },
        'real\labuan_financial' => {
            landing_company_short => 'labuan',
            account_type          => 'real',
            sub_account_type      => 'std',
            server_type           => '01',
            market_type           => 'financial',
            currency              => 'usd',
        },
        'real\vanuatu_financial' => {
            landing_company_short => 'vanuatu',
            account_type          => 'real',
            sub_account_type      => 'std',
            server_type           => '01',
            market_type           => 'financial',
            currency              => 'usd',
        },
        'real\maltainvest_financial' => {
            landing_company_short => 'maltainvest',
            account_type          => 'real',
            sub_account_type      => 'std',
            server_type           => '01',
            market_type           => 'financial',
            currency              => 'usd',
        },
        'real\labuan_financial_stp' => {
            landing_company_short => 'labuan',
            account_type          => 'real',
            sub_account_type      => 'stp',
            server_type           => '01',
            market_type           => 'financial',
            currency              => 'usd',
        },
        'demo\maltainvest_financial_stp_GBP' => {
            landing_company_short => 'maltainvest',
            account_type          => 'demo',
            sub_account_type      => 'stp',
            server_type           => '01',
            market_type           => 'financial',
            currency              => 'gbp',
        },
        'real\maltainvest_financial_GBP' => {
            landing_company_short => 'maltainvest',
            account_type          => 'real',
            sub_account_type      => 'std',
            server_type           => '01',
            market_type           => 'financial',
            currency              => 'gbp',
        },
        'real\maltainvest_financial_stp_gbp' => {
            landing_company_short => 'maltainvest',
            account_type          => 'real',
            sub_account_type      => 'stp',
            server_type           => '01',
            market_type           => 'financial',
            currency              => 'gbp',
        },
        undef => {
            landing_company_short => undef,
            account_type          => undef,
            sub_account_type      => undef,
            server_type           => undef,
            market_type           => undef,
            currency              => undef,
        },
        '' => {
            landing_company_short => undef,
            account_type          => undef,
            sub_account_type      => undef,
            server_type           => undef,
            market_type           => undef,
            currency              => undef,
        },
    );

    is_deeply parse_mt5_group($_), $dataset{$_}, "MT5 group parsed successful: " . ($_ // 'undef') for (keys %dataset);
};

subtest 'MT5 suspended' => sub {
    my $suspend_all_origin         = BOM::Config::Runtime->instance->app_config->system->mt5->suspend->all;
    my $suspend_deposits_origin    = BOM::Config::Runtime->instance->app_config->system->mt5->suspend->deposits;
    my $suspend_withdrawals_origin = BOM::Config::Runtime->instance->app_config->system->mt5->suspend->withdrawals;
    my $guard                      = guard {
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->all($suspend_all_origin);
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->deposits($suspend_deposits_origin);
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->withdrawals($suspend_withdrawals_origin);
    };

    my @cmds = qw(UserDepositChange UserAdd UserGet UserUpdate UserPasswordCheck PositionGetTotal GroupGet UserLogins);
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->all(1);
    my $deposit_cmd = shift @cmds;
    for my $cmd (@cmds) {
        my $fail_result = BOM::MT5::User::Async::is_suspended($cmd, {}) // {};
        is($fail_result, 'MT5APISuspendedError', "mt5 $cmd suspeneded when set all as true");
    }
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->all(0);
    for my $cmd (@cmds) {
        my $fail_result = BOM::MT5::User::Async::is_suspended($cmd, {login => 'MTR1023'});
        ok(!$fail_result, "mt5 $cmd not suspeneded when not set suspended");
    }
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->deposits(1);
    for my $cmd (@cmds) {
        my $fail_result = BOM::MT5::User::Async::is_suspended($cmd, {login => 'MTR1023'});
        ok(!$fail_result, "mt5 $cmd not suspeneded when only set deposit suspended");
    }
    my $fail_result = BOM::MT5::User::Async::is_suspended(
        $deposit_cmd,
        {
            login       => 'MTR1023',
            new_deposit => 1
        });
    is($fail_result, 'MT5REALDepositSuspended', 'deposit suspended when set deposit suspended');
    $fail_result = BOM::MT5::User::Async::is_suspended(
        $deposit_cmd,
        {
            login       => 'MTR1023',
            new_deposit => -1
        });
    ok(!$fail_result, 'withdrawals not suspended when set deposit suspended');
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->deposits(0);
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->withdrawals(1);
    for my $cmd (@cmds) {
        my $fail_result = BOM::MT5::User::Async::is_suspended($cmd, {login => 'MTR1023'});
        ok(!$fail_result, "mt5 $cmd not suspeneded when only set withdrawals suspended");
    }
    $fail_result = BOM::MT5::User::Async::is_suspended(
        $deposit_cmd,
        {
            login       => 'MTR1023',
            new_deposit => 1
        });
    ok(!$fail_result, 'deposit not suspended when set withdrawals suspended');
    $fail_result = BOM::MT5::User::Async::is_suspended(
        $deposit_cmd,
        {
            login       => 'MTR1023',
            new_deposit => -1
        });
    is($fail_result, 'MT5REALWithdrawalSuspended', 'withdrawals suspended when set withdrawals suspended');

    $fail_result = {};
    BOM::MT5::User::Async::_invoke_mt5(
        $deposit_cmd,
        {
            login       => 'MTR1023',
            new_deposit => -1
        })->else(sub { $fail_result = shift; return Future->done })->get;
    is(
        $fail_result->{code},
        BOM::MT5::User::Async::is_suspended(
            $deposit_cmd,
            {
                login       => 'MTR1023',
                new_deposit => -1
            }
        ),
        '_invoke_mt5 will fail with the value of  is_suspended when is_suspended return true'
    );
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->withdrawals(0);

    subtest 'suspend real' => sub {
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real01->all(1);
        for my $cmd (@cmds) {
            my $fail_result = BOM::MT5::User::Async::is_suspended($cmd, {login => 'MTR1023'}) // {};
            is($fail_result, 'MT5REALAPISuspendedError', "mt5 $cmd suspeneded for MTR1023 when set real as true");
            my $pass_result = BOM::MT5::User::Async::is_suspended($cmd, {login => 'MTD1023'});
            ok !$pass_result, "mt5 $cmd not suspended for MTD1023 when set real as true";
        }
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real01->all(0);

        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real02->all(1);
        for my $cmd (@cmds) {
            my $fail_result = BOM::MT5::User::Async::is_suspended($cmd, {login => 'MTR20000000'}) // {};
            is($fail_result, 'MT5REALAPISuspendedError', "mt5 $cmd suspeneded for MTR20000000 when set real as true");
            my $pass_result = BOM::MT5::User::Async::is_suspended($cmd, {login => 'MTD1023'});
            ok !$pass_result, "mt5 $cmd not suspended for MTD1023 when set real as true";
        }
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real02->all(0);
    };

    subtest 'suspend deposit/withdrawal' => sub {
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real01->deposits(1);
        my $fail_result = BOM::MT5::User::Async::is_suspended(
            $deposit_cmd,
            {
                login       => 'MTR1023',
                new_deposit => 1
            }) // {};
        is($fail_result, 'MT5REALDepositSuspended', "mt5 $deposit_cmd suspeneded for MTR1023 when set real01->deposits as true");
        my $pass_result = BOM::MT5::User::Async::is_suspended(
            $deposit_cmd,
            {
                login       => 'MTR20000000',
                new_deposit => 1
            });
        ok !$pass_result, "mt5 $deposit_cmd not suspended for MTR20000000 when set real01->deposits as true";
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real01->deposits(0);

        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real01->withdrawals(1);
        $fail_result = BOM::MT5::User::Async::is_suspended(
            $deposit_cmd,
            {
                login       => 'MTR1023',
                new_deposit => -1
            }) // {};
        is($fail_result, 'MT5REALWithdrawalSuspended', "mt5 $deposit_cmd suspeneded for MTR1023 when set real01->withdrawals as true");
        $pass_result = BOM::MT5::User::Async::is_suspended(
            $deposit_cmd,
            {
                login       => 'MTR20000000',
                new_deposit => -1
            });
        ok !$pass_result, "mt5 $deposit_cmd not suspended for MTR20000000 when set real01->withdrawals as true";
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real01->deposits(0);
    };

    subtest 'suspend demo' => sub {
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->demo01(1);
        for my $cmd (@cmds) {
            my $fail_result = BOM::MT5::User::Async::is_suspended($cmd, {login => 'MTD1023'}) // {};
            is($fail_result, 'MT5DEMOAPISuspendedError', "mt5 $cmd suspeneded for MTD1023 when set demo as true");
            my $pass_result = BOM::MT5::User::Async::is_suspended($cmd, {login => 'MTR1023'});
            ok !$pass_result, "mt5 $cmd not suspended for MTR1023 when set demo as true";
        }
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->demo01(0);
    };
};

subtest 'MT5 ConnectionTimeout Error' => sub {
    my $mock_server_key = Test::MockModule->new('BOM::MT5::User::Async');
    $mock_server_key->mock('get_trading_server_key', sub { 'main' });

    my $timeout_return = {
        error => undef,
        code  => 'ConnectionTimeout'
    };
    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

    my $details = {
        login    => 'MTR1000',
        password => 'FakePass',
    };

    my $mock_config = Test::MockModule->new('BOM::Config');
    $mock_config->mock('mt5_webapi_config', sub { +{request_timeout => 1} });

    my $circuit_breaker = BOM::MT5::Utility::CircuitBreaker->new(
        server_type => 'real',
        server_code => 'main'
    );

    # reset the circuit status before start testing
    $circuit_breaker->circuit_reset();

    try {
        # This call will be timedout.
        BOM::MT5::User::Async::password_check($details)->get;
        is 1, 0, 'This wont be executed';
    } catch ($e) {
        cmp_deeply($e, $timeout_return, 'Returned timedout connection');
        my $redis_keys_value = $circuit_breaker->_get_keys_value();
        is $redis_keys_value->{failure_count}, 1, 'Fail counter count is updated';
        ok $redis_keys_value->{last_failure_time}, 'Last failure time is updated';
    }
};

done_testing;
