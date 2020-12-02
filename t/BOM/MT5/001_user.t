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
            company  => 'svg',
            category => 'real',
            type     => 'synthetic',
        },
        'real\labuan_financial' => {
            company  => 'labuan',
            category => 'real',
            type     => 'financial',
        },
        'real\vanuatu_financial' => {
            company  => 'vanuatu',
            category => 'real',
            type     => 'financial',
        },
        'real\maltainvest_financial' => {
            company  => 'maltainvest',
            category => 'real',
            type     => 'financial',
        },
        'real\labuan_financial_stp' => {
            company  => 'labuan',
            category => 'real',
            type     => 'financial stp',
        },
        'demo\maltainvest_financial_stp_GBP' => {
            company  => 'maltainvest',
            category => 'demo',
            type     => 'financial stp',
        },
        'abc\cde_fgh_IJK' => {
            company  => 'cde',
            category => 'demo',
            type     => 'synthetic',
        },
        'abc' => {},
        ''    => {},
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
        my $fail_result = BOM::MT5::User::Async::_is_suspended($cmd, {login => 'MTR123'});
        ok(!$fail_result, "mt5 $cmd not suspeneded when not set suspended");
    }
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->deposits(1);
    for my $cmd (@cmds) {
        my $fail_result = BOM::MT5::User::Async::_is_suspended($cmd, {login => 'MTR123'});
        ok(!$fail_result, "mt5 $cmd not suspeneded when only set deposit suspended");
    }
    my $fail_result = BOM::MT5::User::Async::_is_suspended(
        $deposit_cmd,
        {
            login       => 'MTR123',
            new_deposit => 1
        });
    is($fail_result, 'MT5DepositSuspended', 'deposit suspended when set deposit suspended');
    $fail_result = BOM::MT5::User::Async::_is_suspended(
        $deposit_cmd,
        {
            login       => 'MTR123',
            new_deposit => -1
        });
    ok(!$fail_result, 'withdrawals not suspended when set deposit suspended');
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->deposits(0);
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->withdrawals(1);
    for my $cmd (@cmds) {
        my $fail_result = BOM::MT5::User::Async::_is_suspended($cmd, {login => 'MTR123'});
        ok(!$fail_result, "mt5 $cmd not suspeneded when only set withdrawals suspended");
    }
    $fail_result = BOM::MT5::User::Async::_is_suspended(
        $deposit_cmd,
        {
            login       => 'MTR123',
            new_deposit => 1
        });
    ok(!$fail_result, 'deposit not suspended when set withdrawals suspended');
    $fail_result = BOM::MT5::User::Async::_is_suspended(
        $deposit_cmd,
        {
            login       => 'MTR123',
            new_deposit => -1
        });
    is($fail_result, 'MT5WithdrawalSuspended', 'withdrawals suspended when set withdrawals suspended');

    $fail_result = {};
    BOM::MT5::User::Async::_invoke_mt5(
        $deposit_cmd,
        {
            login       => 'MTR123',
            new_deposit => -1
        })->else(sub { $fail_result = shift; return Future->done })->get;
    is(
        $fail_result->{code},
        BOM::MT5::User::Async::_is_suspended(
            $deposit_cmd,
            {
                login       => 'MTR123',
                new_deposit => -1
            }
        ),
        '_invoke_mt5 will fail with the value of  _is_suspended when _is_suspended return true'
    );
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->withdrawals(0);

    subtest 'suspend real' => sub {
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real(1);
        for my $cmd (@cmds) {
            my $fail_result = BOM::MT5::User::Async::_is_suspended($cmd, {login => 'MTR123'}) // {};
            is($fail_result, 'MT5REALAPISuspendedError', "mt5 $cmd suspeneded for MTR123 when set real as true");
            my $pass_result = BOM::MT5::User::Async::_is_suspended($cmd, {login => 'MTD123'});
            ok !$pass_result, "mt5 $cmd not suspended for MTD123 when set real as true";
        }
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real(0);
    };

    subtest 'suspend demo' => sub {
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->demo(1);
        for my $cmd (@cmds) {
            my $fail_result = BOM::MT5::User::Async::_is_suspended($cmd, {login => 'MTD123'}) // {};
            is($fail_result, 'MT5DEMOAPISuspendedError', "mt5 $cmd suspeneded for MTD123 when set demo as true");
            my $pass_result = BOM::MT5::User::Async::_is_suspended($cmd, {login => 'MTR123'});
            ok !$pass_result, "mt5 $cmd not suspended for MTR123 when set demo as true";
        }
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->demo(0);
    };
};

subtest 'MT5 Multi Trading Server' => sub {
    my $mock_mt5_webapi_config = Test::MockModule->new('BOM::MT5::User::Async');
    $mock_mt5_webapi_config->mock(
        'get_mt5_config',
        sub {
            {
                demo => {
                    '01' => {
                        accounts => [{
                                from => 1000,
                                to   => 1000000
                            }
                        ],
                        group_suffix => '01'
                    }
                },
                real => {
                    '01' => {
                        accounts => [{
                                from => 1000,
                                to   => 2000
                            },
                            {
                                from => 2001,
                                to   => 1000000
                            }
                        ],
                        group_suffix => '01'
                    },
                    '02' => {
                        accounts => [{
                                from => 1000001,
                                to   => 2000000
                            }
                        ],
                        group_suffix => '02'
                    }
                },
            };
        });
    is(BOM::MT5::User::Async::_get_trading_server_key({login => 1001},    'real'), '01', 'trading server key "01" for real login 1001 is correct');
    is(BOM::MT5::User::Async::_get_trading_server_key({login => 2020},    'real'), '01', 'trading server key "01" for real login 2020 is correct');
    is(BOM::MT5::User::Async::_get_trading_server_key({login => 1005000}, 'real'), '02', 'trading server key "02" for real login 1005000 is correct');
    is(BOM::MT5::User::Async::_get_trading_server_key({login => 1001},    'demo'), '01', 'trading server key "01" for demo login 1001 is correct');
    like(
        exception { BOM::MT5::User::Async::_get_trading_server_key({login => 1005000}, 'demo') },
        qr/Unexpected login/,
        'out of range login caught okay'
    );
    is(BOM::MT5::User::Async::_get_trading_server_key({group => 'real\svg'}, 'real'), '01', 'trading server key "01" for group real\svg is correct');
    is(
        BOM::MT5::User::Async::_get_trading_server_key({
                group =>,
                'real02\svg'
            },
            'real'
        ),
        '02',
        'trading server key "02" for group real02\svg is correct'
    );
    is(BOM::MT5::User::Async::_get_trading_server_key({group => 'demo\svg_financial'}, 'demo'),
        '01', 'trading server key "01" for group demo\svg_financial is correct');
    is(BOM::MT5::User::Async::_get_trading_server_key({group => 'demo\labuan_financial_stp_01'}, 'demo'),
        '01', 'trading server key "01" for group demo\labuan_financial_stp_01 is correct');

    my $mt5_config = BOM::MT5::User::Async::get_mt5_config();
    $mt5_config->{'real'}->{'01'}->{group_suffix} = '';
    $mock_mt5_webapi_config->redefine('get_mt5_config', sub { $mt5_config });

    is(BOM::MT5::User::Async::_get_trading_server_key({group => 'real\labuan_financial_stp'}, 'real'),
        '01', 'trading server key "01" for group real\labuan_financial_stp is correct (suffix changed to empty string)');

    $mt5_config->{'real'}->{'01'}->{group_suffix} = '01';
    $mock_mt5_webapi_config->redefine('get_mt5_config', sub { $mt5_config });

    my $invoked_params;
    my $mock_mt5_invoke = Test::MockModule->new('BOM::MT5::User::Async');
    $mock_mt5_invoke->mock(
        '_invoke_mt5',
        sub {
            my ($cmd, $params) = @_;
            $invoked_params = $params;
            Future->done({login => 1});
        });

    BOM::MT5::User::Async::create_user({
            country => 'Indonesia',
            group   => 'real\svg'
        })->get;
    is($invoked_params->{group}, 'real01\svg', 'server 01 is selected for Indonesian real user');

    my $mock_mt5_countries_list = Test::MockModule->new('BOM::MT5::User::Async');
    $mock_mt5_countries_list->mock(
        '_get_country_server',
        sub {
            print "Mock countty serbrt " . $BOM::MT5::User::Async::DEFAULT_TRADING_SERVER_KEY . "\n";
            my %SERVER_FOR_COUNTRY = (
                demo => {id => '02'},
                real => {
                    za => '02',
                    ng => '02',
                });
            my ($account_type, $country) = @_;
            return $SERVER_FOR_COUNTRY{$account_type}->{country2code($country)} // $BOM::MT5::User::Async::DEFAULT_TRADING_SERVER_KEY;
        });

    $mt5_config->{'demo'}->{'02'} = {
        accounts => [{
                from => 1000001,
                to   => 2000000
            }
        ],
        group_suffix => '02'
    };
    $mock_mt5_webapi_config->redefine('get_mt5_config', sub { $mt5_config });

    delete $invoked_params->{group};
    BOM::MT5::User::Async::create_user({
            country => 'Nigeria',
            group   => 'real\svg'
        })->get;
    is($invoked_params->{group}, 'real02\svg', 'server 02 is selected for Nigeria real user');

    delete $invoked_params->{group};
    BOM::MT5::User::Async::create_user({
            country => 'South Africa',
            group   => 'real\svg_financial'
        })->get;
    is($invoked_params->{group}, 'real02\svg_financial', 'server 02 is selected for South Africa real user');

    delete $invoked_params->{group};
    BOM::MT5::User::Async::create_user({
            country => 'Nigeria',
            group   => 'demo\svg'
        })->get;
    is($invoked_params->{group}, 'demo01\svg', 'server 01 is selected for Nigeria demo user');

    delete $invoked_params->{group};
    BOM::MT5::User::Async::create_user({
            country => 'Indonesia',
            group   => 'demo\svg_financial'
        })->get;
    is($invoked_params->{group}, 'demo02\svg_financial', 'server 02 is selected for Indonesia demo user');

};

done_testing;
