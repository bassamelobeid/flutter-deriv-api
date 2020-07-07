#!perl

use strict;
use warnings;

use Test::More;
use Test::Deep qw(cmp_deeply);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::MT5::User::Async;
use BOM::User::Utility qw(parse_mt5_group);
use Syntax::Keyword::Try;
use BOM::Config::Runtime;
use Scope::Guard qw(guard);

my $FAILCOUNT_KEY     = 'system.mt5.connection_fail_count';
my $LOCK_KEY          = 'system.mt5.connection_status';
my $BACKOFF_THRESHOLD = 20;
my $BACKOFF_TTL       = 60;

subtest 'MT5 Timeout logic handle' => sub {
    my $timeout_return = {
        error => 'ConnectionTimeout',
        code  => 'ConnectionTimeout'
    };
    my $blocked_return = {
        error => undef,
        code  => 'NoConnection'
    };
    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');
    my $details = {group => 'real//svg_standard'};
    my $redis = BOM::Config::Redis::redis_mt5_user_write();
    # reset all redis keys.
    $redis->del($FAILCOUNT_KEY);
    $redis->del($LOCK_KEY);
    for my $i (1 .. 24) {
        try {
            # this will produce a fialed response
            BOM::MT5::User::Async::create_user($details)->get;
        }
        catch {
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
    }
    catch {
        my $result = $@;
        cmp_deeply($result, $blocked_return, 'Call has been blocked.');
    }

    # Expire the key. as if a minute has passed.
    $redis->expire($FAILCOUNT_KEY, 0);

    try {
        # This call will be timedout.
        BOM::MT5::User::Async::create_user($details)->get;
        is 1, 0, 'This wont be executed';
    }
    catch {
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

};

subtest 'parse mt5 group' => sub {
    my %dataset = (
        'real\svg' => {
            company    => 'svg',
            category   => 'real',
            type       => 'gaming',
            subtype    => '',
            type_label => 'synthetic',
            currency   => 'USD',
        },
        'real\labuan_standard' => {
            company    => 'labuan',
            category   => 'real',
            type       => 'financial',
            subtype    => 'standard',
            type_label => 'financial',
            currency   => 'USD',
        },
        'demo\maltainvest_advanced_GBP' => {
            company    => 'maltainvest',
            category   => 'demo',
            type       => 'financial',
            subtype    => 'advanced',
            type_label => 'financial stp',
            currency   => 'GBP',
        },
        'real\maltainvest_advanced_gbp' => {
            company    => 'maltainvest',
            category   => 'real',
            type       => 'financial',
            subtype    => 'advanced',
            type_label => 'financial stp',
            currency   => 'USD',             # lower-case currency is not matched; it should fallback to the default value
        },
        'abc\cde_fgh_IJK' => {
            company    => 'cde',
            category   => 'abc',
            type       => 'financial',
            subtype    => 'fgh',
            type_label => '',

            currency => 'IJK',
        },
        'abc\cde' => {
            company    => 'cde',
            category   => 'abc',
            type       => 'gaming',
            subtype    => '',
            type_label => 'synthetic',
            currency   => 'USD',
        },
        'abc' => {
            company    => '',
            category   => '',
            type       => '',
            subtype    => '',
            type_label => '',
            currency   => '',
        },
        '' => {
            company    => '',
            category   => '',
            type       => '',
            subtype    => '',
            type_label => '',
            currency   => '',
        },
        undef => {
            company    => '',
            category   => '',
            type       => '',
            subtype    => '',
            type_label => '',

            type     => '',
            currency => '',
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
        my $fail_result = BOM::MT5::User::Async::_is_suspended($cmd, {}) // {};
        is($fail_result, 'MT5APISuspendedError', "mt5 $cmd suspeneded when set all as true");
    }
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->all(0);
    for my $cmd (@cmds) {
        my $fail_result = BOM::MT5::User::Async::_is_suspended($cmd, {});
        ok(!$fail_result, "mt5 $cmd not suspeneded when not set suspended");
    }
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->deposits(1);
    for my $cmd (@cmds) {
        my $fail_result = BOM::MT5::User::Async::_is_suspended($cmd, {});
        ok(!$fail_result, "mt5 $cmd not suspeneded when only set deposit suspended");
    }
    my $fail_result = BOM::MT5::User::Async::_is_suspended($deposit_cmd, {new_deposit => 1});
    is($fail_result, 'MT5DepositSuspended', 'deposit suspended when set deposit suspended');
    $fail_result = BOM::MT5::User::Async::_is_suspended($deposit_cmd, {new_deposit => -1});
    ok(!$fail_result, 'withdrawals not suspended when set deposit suspended');
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->deposits(0);
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->withdrawals(1);
    for my $cmd (@cmds) {
        my $fail_result = BOM::MT5::User::Async::_is_suspended($cmd, {});
        ok(!$fail_result, "mt5 $cmd not suspeneded when only set withdrawals suspended");
    }
    $fail_result = BOM::MT5::User::Async::_is_suspended($deposit_cmd, {new_deposit => 1});
    ok(!$fail_result, 'deposit not suspended when set withdrawals suspended');
    $fail_result = BOM::MT5::User::Async::_is_suspended($deposit_cmd, {new_deposit => -1});
    is($fail_result, 'MT5WithdrawalSuspended', 'withdrawals suspended when set withdrawals suspended');

    $fail_result = {};
    BOM::MT5::User::Async::_invoke_mt5($deposit_cmd, {new_deposit => -1})->else(sub { $fail_result = shift; return Future->done })->get;
    is(
        $fail_result->{code},
        BOM::MT5::User::Async::_is_suspended($deposit_cmd, {new_deposit => -1}),
        '_invoke_mt5 will fail with the value of  _is_suspended when _is_suspended return true'
    );
};

done_testing;
