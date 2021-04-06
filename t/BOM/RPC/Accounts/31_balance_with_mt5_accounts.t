#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use Test::BOM::RPC::QueueClient;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Token::API;
use BOM::User::Password;
use BOM::User;
use BOM::Test::Helper::Token;
use Test::BOM::RPC::Accounts;

BOM::Test::Helper::Token::cleanup_redis_tokens();

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my %ACCOUNTS       = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %DETAILS        = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;
my %financial_data = %Test::BOM::RPC::Accounts::FINANCIAL_DATA;

my $t_mock = Test::MockModule->new('BOM::RPC::v3::Accounts');
$t_mock->mock('_mt5_balance_call_enabled', sub { return 1 });
my $method = 'balance';

subtest 'balance with mt5 disabled' => sub {
    my $email       = 'abccr@binary.com';
    my $password    = 'jskjd8292922';
    my $hash_pwd    = BOM::User::Password::hashpw($password);
    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $m = BOM::Platform::Token::API->new;
    my $c = Test::BOM::RPC::QueueClient->new();
    $test_client->email($email);
    $test_client->save;

    my $test_loginid = $test_client->loginid;
    my $user         = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->add_client($test_client);
    my $token = $m->create_token($test_loginid, 'test token');

    $test_client->set_default_account('USD');
    $test_client->save;

    $test_client->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );

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
    my $result  = $c->tcall(
        $method,
        {
            token      => $token,
            token_type => 'oauth_token',
            args       => {
                balance => 1,
                account => 'all'
            }});
    ok $result->{accounts}, 'accounts exists';
    ok $result->{accounts}{$test_loginid}{status},   'account status is ok';
    is $result->{accounts}{$test_loginid}{currency}, 'USD',     'account currency is USD';
    is $result->{accounts}{$test_loginid}{balance},  '1000.00', 'account balance is 1000.00';
    is $result->{accounts}{$test_loginid}{type},     'deriv',   'account type is deriv';
    # mt5
    ok $result->{accounts}{MTR41000001}{status},   'account status is ok';
    is $result->{accounts}{MTR41000001}{currency}, 'USD',     'account currency is USD';
    is $result->{accounts}{MTR41000001}{balance},  '1234.00', 'account balance is 1234.00';
    is $result->{accounts}{MTR41000001}{type},     'mt5',     'account type is mt5';
    # total
    is $result->{total}{mt5_demo}{amount},   '0.00',    'mt5 demo amount 0.00';
    is $result->{total}{mt5}{amount},        '1234.00', 'mt5 amount 1234.00';
    is $result->{total}{deriv_demo}{amount}, '0.00',    'deriv demo amount 0.00';
    is $result->{total}{deriv}{amount},      '1000.00', 'deriv amount 1000.00';

    note("disable real03 API call");
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(1);
    $result = $c->tcall(
        $method,
        {
            token      => $token,
            token_type => 'oauth_token',
            args       => {
                balance => 1,
                account => 'all'
            }});

    ok $result->{accounts}{$test_loginid}{status},   'account status is ok';
    is $result->{accounts}{$test_loginid}{currency}, 'USD',     'account currency is USD';
    is $result->{accounts}{$test_loginid}{balance},  '1000.00', 'account balance is 1000.00';
    is $result->{accounts}{$test_loginid}{type},     'deriv',   'account type is deriv';
    # mt5
    ok !$result->{accounts}{MTR41000001}{status}, 'account status is not ok';
    is $result->{accounts}{MTR41000001}{currency}, '',     'account currency is \'\'';
    is $result->{accounts}{MTR41000001}{balance},  '0.00', 'account balance is 0.00';
    is $result->{accounts}{MTR41000001}{type},     'mt5',  'account type is mt5';
    # total
    is $result->{total}{mt5_demo}{amount},   '0.00',    'mt5 demo amount 0.00';
    is $result->{total}{mt5}{amount},        '0.00',    'mt5 amount 0.00';
    is $result->{total}{deriv_demo}{amount}, '0.00',    'deriv demo amount 0.00';
    is $result->{total}{deriv}{amount},      '1000.00', 'deriv amount 1000.00';

    # create mt5 financial account
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $mt5_params->{args}{account_type}     = 'financial';
    $mt5_params->{args}{mt5_account_type} = 'financial';
    $mt5_params->{args}{email}            = '123' . $mt5_params->{args}{email};
    my $mt5_financial_acc = $c->tcall('mt5_new_account', $mt5_params);

    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(1);
    $result = $c->tcall(
        $method,
        {
            token      => $token,
            token_type => 'oauth_token',
            args       => {
                balance => 1,
                account => 'all'
            }});

    ok $result->{accounts}{$test_loginid}{status},   'account status is ok';
    is $result->{accounts}{$test_loginid}{currency}, 'USD',     'account currency is USD';
    is $result->{accounts}{$test_loginid}{balance},  '1000.00', 'account balance is 1000.00';
    is $result->{accounts}{$test_loginid}{type},     'deriv',   'account type is deriv';
    # mt5
    ok !$result->{accounts}{MTR41000001}{status}, 'account status is not ok';
    is $result->{accounts}{MTR41000001}{currency}, '',     'account currency is \'\'';
    is $result->{accounts}{MTR41000001}{balance},  '0.00', 'account balance is 0.00';
    is $result->{accounts}{MTR41000001}{type},     'mt5',  'account type is mt5';

    ok $result->{accounts}{MTR1001016}{status},   'account status is 1';
    is $result->{accounts}{MTR1001016}{currency}, 'USD',     'account currency is USD';
    is $result->{accounts}{MTR1001016}{balance},  '1234.00', 'account balance is 1234.00';
    is $result->{accounts}{MTR1001016}{type},     'mt5',     'account type is mt5';
    # total
    is $result->{total}{mt5_demo}{amount},   '0.00',    'mt5 demo amount 0.00';
    is $result->{total}{mt5}{amount},        '1234.00', 'mt5 amount 1234.00';
    is $result->{total}{deriv_demo}{amount}, '0.00',    'deriv demo amount 0.00';
    is $result->{total}{deriv}{amount},      '1000.00', 'deriv amount 1000.00';

    note("enable real03 API call");
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);
};

done_testing();
