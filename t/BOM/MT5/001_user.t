#!perl

use strict;
use warnings;

use Test::More;
use Test::Deep qw(cmp_deeply);
use Test::MockModule;
use Test::Fatal;
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::MT5::User::Async;
use BOM::User::Utility qw(parse_mt5_group);
use Syntax::Keyword::Try;
use BOM::Config::Runtime;
use Scope::Guard qw(guard);
use Locale::Country qw(country2code);

my $FAILCOUNT_KEY     = 'system.mt5.connection_fail_count';
my $LOCK_KEY          = 'system.mt5.connection_status';
my $BACKOFF_THRESHOLD = 20;
my $BACKOFF_TTL       = 60;

subtest 'MT5 Timeout logic handle' => sub {
    my $mock_server_key = Test::MockModule->new('BOM::MT5::User::Async');
    $mock_server_key->mock('_get_trading_server_key', sub { 'main' });

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
    my $redis   = BOM::Config::Redis::redis_mt5_user_write();
    # reset all redis keys.
    $redis->del($FAILCOUNT_KEY);
    $redis->del($LOCK_KEY);
    for my $i (1 .. 24) {
        try {
            # this will produce a fialed response
            BOM::MT5::User::Async::create_user($details)->get;
        } catch {
            my $result = $@;
            # We will keep trying to connect for the first 20 calls.
            if ($i <= 20) {
                cmp_deeply($result, $timeout_return, 'Returned timedout connection');

                is $redis->get($FAILCOUNT_KEY), $i,           'Fail counter count is updated';
                is $redis->ttl($FAILCOUNT_KEY), $BACKOFF_TTL, 'Fail counter TTL is updated';
                # After that we will set a failure flag, and block further requests
            } elsif ($i == 21) {
                cmp_deeply($result, $blocked_return, 'Call has been blocked');
                is $redis->get($LOCK_KEY), 1, 'lock has been set';
            } elsif ($i > 21) {
                # further calls will be blocked.
                cmp_deeply($result, $blocked_return, 'Call has been blocked');
            }
        }
    }

    is $redis->get($LOCK_KEY), 1, 'lock has been set';
    try {
        # This call will be blocked.
        BOM::MT5::User::Async::get_user('MTR1000')->get;
        is 1, 0, 'This wont be executed';
    } catch {
        my $result = $@;
        cmp_deeply($result, $blocked_return, 'Call has been blocked.');
    }

    # Expire the key. as if a minute has passed.
    $redis->expire($FAILCOUNT_KEY, 0);

    try {
        # This call will be timedout.
        BOM::MT5::User::Async::create_user($details)->get;
        is 1, 0, 'This wont be executed';
    } catch {
        my $result = $@;
        cmp_deeply($result, $timeout_return, 'Returned timedout connection');
    }

    # Expire the key. as if a minute has passed.
    $redis->expire($FAILCOUNT_KEY, 0);
    # Do a successful call
    is $redis->get($LOCK_KEY), 1, 'lock has been set';
    my $first_success = BOM::MT5::User::Async::get_user('MTR1000')->get;
    is $first_success->{login}, 'MTR1000', 'Return is correct';
    # Flags should be reset.
    is $redis->get($LOCK_KEY), 0, 'lock has been reset';

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
        ''    => {
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
    is($fail_result, 'MT5REAL01DepositSuspended', 'deposit suspended when set deposit suspended');
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
    is($fail_result, 'MT5REAL01WithdrawalSuspended', 'withdrawals suspended when set withdrawals suspended');

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
            is($fail_result, 'MT5REAL01APISuspendedError', "mt5 $cmd suspeneded for MTR1023 when set real as true");
            my $pass_result = BOM::MT5::User::Async::is_suspended($cmd, {login => 'MTD1023'});
            ok !$pass_result, "mt5 $cmd not suspended for MTD1023 when set real as true";
        }
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real01->all(0);

        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real02->all(1);
        for my $cmd (@cmds) {
            my $fail_result = BOM::MT5::User::Async::is_suspended($cmd, {login => 'MTR20000000'}) // {};
            is($fail_result, 'MT5REAL02APISuspendedError', "mt5 $cmd suspeneded for MTR20000000 when set real as true");
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
        is($fail_result, 'MT5REAL01DepositSuspended', "mt5 $deposit_cmd suspeneded for MTR1023 when set real01->deposits as true");
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
        is($fail_result, 'MT5REAL01WithdrawalSuspended', "mt5 $deposit_cmd suspeneded for MTR1023 when set real01->withdrawals as true");
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

done_testing;
