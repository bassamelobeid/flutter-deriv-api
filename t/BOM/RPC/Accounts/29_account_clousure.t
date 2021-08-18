use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Platform::Token::API;
use BOM::User::Password;
use BOM::User;
use BOM::User::Client;
use BOM::Test::Helper::Token;
use Test::BOM::RPC::Accounts;
use Test::BOM::RPC::QueueClient;
use BOM::Test::Script::DevExperts;
use BOM::Config::Runtime;

BOM::Test::Helper::Token::cleanup_redis_tokens();
my $password = 'jskjd8292922';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $m = BOM::Platform::Token::API->new;

my $c = Test::BOM::RPC::QueueClient->new();

my $method = 'account_closure';
my $args   = {
    "account_closure" => 1,
    "reason"          => 'Financial concerns'
};

subtest 'account closure' => sub {
    my $email = 'def456@email.com';

    # Create user
    my $user = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );

    my $new_client_handler = sub {
        my ($broker_code, $currency) = @_;
        $currency //= 'USD';

        my $new_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => $broker_code});

        $new_client->set_default_account($currency);
        $new_client->email($email);
        $new_client->save;
        $user->add_client($new_client);

        return $new_client;
    };

    my $payment_handler = sub {
        my ($client, $amount) = @_;

        $client->payment_legacy_payment(
            currency     => $client->currency,
            amount       => $amount,
            remark       => 'testing',
            payment_type => 'ewallet'
        );

        return 1;
    };

    # Create VR client
    my $test_client_vr = $new_client_handler->('VRTC');

    # Create CR client (first)
    my $test_client = $new_client_handler->('CR');

    # Tokens

    my $token = $m->create_token($test_client->loginid, 'test token');

    my $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args
        });

    # Test with single real account (no balance)
    # Test with virtual account
    is($res->{status}, 1, 'Successfully received request');
    ok($test_client_vr->status->disabled, 'Virtual account disabled');
    ok($test_client->status->disabled,    'CR account disabled');
    ok($test_client_vr->status->closed,   'Virtual account self-closed status');
    ok($test_client->status->closed,      'CR account self-closed status');

    $test_client_vr->status->clear_disabled;
    $test_client->status->clear_disabled;

    ok(!$test_client->status->disabled, 'CR account is enabled back again');
    ok(!$test_client->status->closed,   'self-closed status removed from CR account');
    subtest "Open Contracts" => sub {
        my $mock = Test::MockModule->new('BOM::User::Client');
        $mock->mock(
            get_open_contracts => sub {
                return [1];
            });

        $res = $c->tcall(
            $method,
            {
                token => $token,
                args  => $args
            });

        is($res->{error}->{code}, 'AccountHasPendingConditions', 'Correct error code');
        my $loginid = $test_client->loginid;
        is(
            $res->{error}->{message_to_client},
            "Please close open positions and withdraw all funds from your $loginid account(s). Also, notice if you have pending withdrawal requests, wait for those to be finalized first before proceeding.",
            "Correct error message"
        );
        is_deeply($res->{error}->{details}, {open_positions => {$loginid => 1}}, "Correct error details");
        ok(!$test_client->status->disabled,    'CR account is not disabled');
        ok(!$test_client_vr->status->disabled, 'Virtual account is also not disabled');
        ok(!$test_client_vr->status->closed,   'Virtual account has no self-closed status');
        ok(!$test_client->status->closed,      'CR account has no self-closed status');

        $mock->unmock_all;
        $test_client_vr->status->clear_disabled;
        $test_client->status->clear_disabled;
    };

    subtest "Pending payouts" => sub {
        $test_client->incr_df_payouts_count('test_trace_id');
        $res = $c->tcall(
            $method,
            {
                token => $token,
                args  => $args
            });

        is($res->{error}->{code}, 'AccountHasPendingConditions', 'Correct error code');
        my $loginid = $test_client->loginid;
        is(
            $res->{error}->{message_to_client},
            "Please close open positions and withdraw all funds from your $loginid account(s). Also, notice if you have pending withdrawal requests, wait for those to be finalized first before proceeding.",
            "Correct error message"
        );
        is_deeply($res->{error}->{details}, {pending_withdrawals => {$loginid => 1}}, "Correct error details");
        ok(!$test_client->status->disabled,    'CR account is not disabled');
        ok(!$test_client_vr->status->disabled, 'Virtual account is also not disabled');
        ok(!$test_client_vr->status->closed,   'Virtual account has no self-closed status');
        ok(!$test_client->status->closed,      'CR account has no self-closed status');

        $test_client->decr_df_payouts_count('test_trace_id');
    };

    $payment_handler->($test_client, 1);

    $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args
        });

    # Test with single real account (balance)
    is($res->{error}->{code}, 'AccountHasPendingConditions', 'Correct error code');
    ok(!$test_client->status->disabled,    'CR account is not disabled');
    ok(!$test_client_vr->status->disabled, 'Virtual account is also not disabled');
    ok(!$test_client_vr->status->closed,   'Virtual account has no self-closed status');
    ok(!$test_client->status->closed,      'CR account has no self-closed status');

    my $test_client_2 = $new_client_handler->('CR', 'BTC');
    $payment_handler->($test_client,   -1);
    $payment_handler->($test_client_2, 1);

    $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args
        });

    # Test with real siblings account (balance)
    my $loginid = $test_client_2->loginid;
    is($res->{error}->{code}, 'AccountHasPendingConditions', 'Correct error code');
    is(
        $res->{error}->{message_to_client},
        "Please close open positions and withdraw all funds from your $loginid account(s). Also, notice if you have pending withdrawal requests, wait for those to be finalized first before proceeding.",
        'Correct error message for sibling account'
    );
    is_deeply(
        $res->{error}->{details},
        {
            balance => {
                $loginid => {
                    balance  => "1.00000000",
                    currency => 'BTC'
                }}
        },
        'Correct array in details'
    );
    is($test_client->account->balance, '0.00', 'CR (USD) has no balance');
    ok(!$test_client->status->disabled,   'CR account is not disabled');
    ok(!$test_client_2->status->disabled, 'Sibling account is also not disabled');
    ok(!$test_client->status->closed,     'Virtual account has no self-closed status');
    ok(!$test_client_2->status->closed,   'CR account has no self-closed status');

    # Test with siblings account (has balance)
    $payment_handler->($test_client_2, -1);

    $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args
        });

    $test_client_vr = BOM::User::Client->new({loginid => $test_client_vr->loginid});
    $test_client    = BOM::User::Client->new({loginid => $test_client->loginid});
    $test_client_2  = BOM::User::Client->new({loginid => $test_client_2->loginid});

    my $disabled_hashref = $test_client_2->status->disabled;

    is($res->{status},                  1,                     'Successfully received request');
    is($disabled_hashref->{reason},     $args->{reason},       'Correct message for reason');
    is($disabled_hashref->{staff_name}, $test_client->loginid, 'Correct loginid');
    ok($test_client_vr->status->disabled, 'Virtual account disabled');
    ok($test_client->status->disabled,    'CR account disabled');
    ok($test_client_vr->status->closed,   'Virtual account self-closed status');
    ok($test_client->status->closed,      'CR account self-closed status');

};

subtest 'Account closure MT5 balance' => sub {

    my $email = 'account_clouser_mt5_tests@example.com';
    my $user  = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRTC'});
    $client->email($email);
    $client->save;
    $user->add_client($client);

    my $token = $m->create_token($client->loginid, 'test token');
    my $args  = {
        "account_closure" => 1,
        "reason"          => 'Financial concerns',
    };

    my $mock_mt5_rpc = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mock_mt5_rpc->mock(
        get_mt5_logins => sub {
            return Future->done({
                login    => 'MTR1',
                group    => 'real/gold_miners',
                balance  => 1000,
                currency => 'USD',
            });
        });

    my $mock_mt5 = Test::MockModule->new('BOM::MT5::User::Async');
    $mock_mt5->mock(get_open_positions_count => sub { return Future->done({total => 0}) });

    my $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args,
        });

    my $expected = {
        error => {
            details => {
                balance => {
                    MTR1 => {
                        balance  => '1000.00',
                        currency => 'USD'
                    }}
            },
            code              => 'AccountHasPendingConditions',
            message_to_client =>
                'Please close open positions and withdraw all funds from your MTR1 account(s). Also, notice if you have pending withdrawal requests, wait for those to be finalized first before proceeding.'
        }};
    is_deeply($res, $expected, 'MT5 account has balance');

    $mock_mt5_rpc->mock(
        get_mt5_logins => sub {
            return Future->done({
                login    => 'MTR1',
                group    => 'real/gold_miners',
                balance  => 0,
                currency => 'USD',
            });
        });
    $mock_mt5->mock(get_open_positions_count => sub { return Future->done({total => 1}) });

    $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args,
        });

    $expected = {
        error => {
            details           => {open_positions => {MTR1 => 1}},
            code              => 'AccountHasPendingConditions',
            message_to_client =>
                'Please close open positions and withdraw all funds from your MTR1 account(s). Also, notice if you have pending withdrawal requests, wait for those to be finalized first before proceeding.'
        }};
    is_deeply($res, $expected, 'MT5 account has open positions');

    $mock_mt5_rpc->mock(
        get_mt5_logins => sub {
            return Future->done({
                login    => 'MTR1',
                group    => 'real/gold_miners',
                balance  => 1000,
                currency => 'USD',
            });
        });
    $mock_mt5->mock(get_open_positions_count => sub { return Future->done({total => 1}) });
    $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args,
        });

    $expected = {
        error => {
            details => {
                open_positions => {MTR1 => 1},
                balance        => {
                    MTR1 => {
                        balance  => '1000.00',
                        currency => 'USD'
                    }}
            },
            code              => 'AccountHasPendingConditions',
            message_to_client =>
                'Please close open positions and withdraw all funds from your MTR1 account(s). Also, notice if you have pending withdrawal requests, wait for those to be finalized first before proceeding.'
        }};
    is_deeply($res, $expected, 'MT5 account has balance and open positions');
    $mock_mt5->unmock_all();
};

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my %ACCOUNTS       = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %DETAILS        = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;
my %financial_data = %Test::BOM::RPC::Accounts::FINANCIAL_DATA;

subtest 'account_closure with mt5 API disabled' => sub {
    my $email       = 'cr@binary.com';
    my $password    = 'jskjd8292922';
    my $hash_pwd    = BOM::User::Password::hashpw($password);
    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $test_client->email($email);
    $test_client->save;

    my $test_loginid = $test_client->loginid;
    my $user         = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->update_trading_password($DETAILS{password}{main});
    $user->add_client($test_client);
    my $token = $m->create_token($test_loginid, 'test token');

    $test_client->set_default_account('USD');
    $test_client->save;

    # mt5 account
    my $mt5_params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            country      => 'id',
            email        => $DETAILS{email},
            name         => $DETAILS{name},
            mainPassword => $DETAILS{password}{main},
            leverage     => 100,
        },
    };
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);
    my $mt5_acc = $c->tcall('mt5_new_account', $mt5_params);

    ok $mt5_acc->{login}, 'mt5 account is created';

    note('suspend real03 mt5 API');
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(1);
    my $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args
        });

    ok $res->{error}, 'properly throws an error';
    is $res->{error}->{code}, 'MT5AccountInaccessible', 'error code is MT5AccountInaccessible';
    is $res->{error}->{message_to_client}, 'The following MT5 account(s) are temporarily inaccessible: MTR41000001. Please try again later.';

    note('enable real03 mt5 API');
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->deposits(1);
    $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args
        });

    note('since this is mocked mt5 account data, I won\'t want to change it.');
    is $res->{error}->{code}, 'AccountHasPendingConditions', 'account has balance error instead of server disabled.';

    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->deposits(0);
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->withdrawals(1);

    $res = $c->tcall(
        $method,
        {
            token => $token,
            args  => $args
        });

    note('since this is mocked mt5 account data, I won\'t want to change it.');
    is $res->{error}->{code}, 'AccountHasPendingConditions', 'account has balance error instead of server disabled.';
};

subtest 'Account closure DXTrader' => sub {
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->demo(0);
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->real(0);

    my $email       = 'dxtrader@binary.com';
    my $password    = 'dxTest0909099';
    my $hash_pwd    = BOM::User::Password::hashpw($password);
    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $test_client->email($email);
    $test_client->save;

    my $test_loginid = $test_client->loginid;
    my $user         = BOM::User->create(
        email    => $email,
        password => $hash_pwd,
    );
    $user->add_client($test_client);
    my $token = $m->create_token($test_loginid, 'test token');

    $test_client->set_default_account('USD');
    $test_client->save;

    BOM::Test::Helper::Client::top_up($test_client, $test_client->currency, 10);

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            market_type  => 'financial',
            account_type => 'demo',
            password     => 'Abcd1234',
            platform     => 'dxtrade',
        },
    };

    my $demo_account = $c->tcall('trading_platform_new_account', $params);
    ok $demo_account->{balance} + 0 > 0, 'demo account has balance';

    $params->{args}{account_type} = 'real';
    my $real_account    = $c->tcall('trading_platform_new_account', $params);
    my $real_account_id = $real_account->{account_id};

    $params->{args} = {
        platform     => 'dxtrade',
        amount       => 10,
        from_account => $test_client->loginid,
        to_account   => $real_account_id,
    };

    $c->tcall('trading_platform_deposit', $params);

    $params->{args} = {
        reason => 'Financial concerns',
    };

    my $account_closure = $c->tcall('account_closure', $params);
    cmp_deeply $account_closure,
        {
        error => {
            message_to_client =>
                "Please close open positions and withdraw all funds from your $real_account_id account(s). Also, notice if you have pending withdrawal requests, wait for those to be finalized first before proceeding.",
            details => {
                balance => {
                    $real_account_id => {
                        'currency' => 'USD',
                        'balance'  => '10.00'
                    }}
            },
            code => 'AccountHasPendingConditions'
        }
        },
        'Cannot close account with dxtrader balance > 0';

    $params->{args} = {
        platform     => 'dxtrade',
        amount       => 10,
        to_account   => $test_client->loginid,
        from_account => $real_account_id,
    };

    $c->tcall('trading_platform_withdrawal', $params);

    $params->{args} = {
        reason => 'Financial concerns',
    };

    BOM::Test::Helper::Client::top_up($test_client, $test_client->currency, -10);

    $account_closure = $c->tcall('account_closure', $params);
    ok $account_closure->{status}, 'Account closure status 1';
    ok($test_client->status->disabled, 'Account disabled');
};

done_testing();
