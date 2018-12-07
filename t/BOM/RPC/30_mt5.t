use strict;
use warnings;
use Guard;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Test::MockTime qw(:all);
use JSON::MaybeUTF8;
use List::Util qw();
use Email::Address::UseXS;
use Email::Folder::Search;
use Format::Util::Numbers qw/financialrounding/;

use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::MT5::User::Async;
use BOM::Platform::Token;
use BOM::User;
use BOM::Config::Runtime;
use BOM::Config::RedisReplicated;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
my $json = JSON::MaybeXS->new;

my $runtime_system = BOM::Config::Runtime->instance->app_config->system;

my $redis = BOM::Config::RedisReplicated::redis_exchangerates_write();

scope_guard { restore_time() };

my $manager_module = Test::MockModule->new('BOM::MT5::User::Async');
$manager_module->mock(
    'deposit',
    sub {
        return Future->done({success => 1});
    });

$manager_module->mock(
    'withdrawal',
    sub {
        return Future->done({success => 1});
    });

# Mocked account details
# This hash shared between three files, and should be kept in-sync to avoid test failures
#   t/BOM/RPC/30_mt5.t
#   t/BOM/RPC/05_accounts.t
#   t/lib/mock_binary_mt5.pl
my %DETAILS = (
    login    => '123454321',
    password => 'Efgh4567',
    email    => 'test.account@binary.com',
    name     => 'Test',
    group    => 'real\costarica',
    country  => 'Malta',
    balance  => '1234.56',
);

# Setup a test user
my $test_client    = create_client('CR');
my $test_client_vr = create_client('VRTC');
$test_client->email($DETAILS{email});
$test_client->set_default_account('USD');
$test_client_vr->email($DETAILS{email});
$test_client_vr->set_default_account('USD');
$test_client->set_authentication('ID_DOCUMENT')->status('pass');
$test_client->save;
$test_client_vr->save;

my $user = BOM::User->create(
    email    => $DETAILS{email},
    password => 's3kr1t',
);
$user->add_client($test_client);
$user->add_client($test_client_vr);

#since we are trying to open a new financial mt5 account we should do the financial assessment first
my %financial_data = (
    "forex_trading_experience"             => "Over 3 years",
    "forex_trading_frequency"              => "0-5 transactions in the past 12 months",
    "binary_options_trading_experience"    => "1-2 years",
    "binary_options_trading_frequency"     => "40 transactions or more in the past 12 months",
    "cfd_trading_experience"               => "1-2 years",
    "cfd_trading_frequency"                => "0-5 transactions in the past 12 months",
    "other_instruments_trading_experience" => "Over 3 years",
    "other_instruments_trading_frequency"  => "6-10 transactions in the past 12 months",
    "employment_industry"                  => "Finance",
    "education_level"                      => "Secondary",
    "income_source"                        => "Self-Employed",
    "net_income"                           => '$25,000 - $50,000',
    "estimated_worth"                      => '$100,000 - $250,000',
    "account_turnover"                     => '$25,000 - $50,000',
    "occupation"                           => 'Managers',
    "employment_status"                    => "Self-Employed",
    "source_of_wealth"                     => "Company Ownership",
);

$test_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
$test_client->save;

my $m        = BOM::Database::Model::AccessToken->new;
my $token    = $m->create_token($test_client->loginid, 'test token');
my $token_vr = $m->create_token($test_client_vr->loginid, 'test token');

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my $mailbox = Email::Folder::Search->new('/tmp/default.mailbox');
$mailbox->init;

# Throttle function limits requests to 1 per minute which may cause
# consecutive tests to fail without a reset.
BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

subtest 'new account' => sub {
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type   => 'gaming',
            country        => 'mt',
            email          => $DETAILS{email},
            name           => $DETAILS{name},
            investPassword => 'Abcd1234',
            mainPassword   => $DETAILS{password},
            leverage       => 100,
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account');
    is($c->result->{login}, $DETAILS{login}, 'result->{login}');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $c->call_ok($method, $params)->has_error('error from duplicate mt5_new_account')
        ->error_code_is('MT5CreateUserError', 'error code for duplicate mt5_new_account');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
};

subtest 'new account with switching' => sub {
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token_vr,
        # Pass this virtual account token to test switching functionality.
        #   If the user has multiple client accounts the Binary.com front-end
        #   will pass to this function whichever one is currently selected.
        #   In this case we can automatically detect that the user has
        #   another account which qualifies them to open MT5 and switch.
        args => {
            account_type   => 'gaming',
            country        => 'mt',
            email          => $DETAILS{email},
            name           => $DETAILS{name},
            investPassword => 'Abcd1234',
            mainPassword   => $DETAILS{password},
            leverage       => 100,
        },
    };
    # Expect error because we opened an account in the previous test.
    $c->call_ok($method, $params)->has_error('error from duplicate mt5_new_account')
        ->error_code_is('MT5CreateUserError', 'error code for duplicate mt5_new_account');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
};

subtest 'authenticated CR client should not receive authentication request when he opens new MT5 financial account' => sub {
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    my $method = 'mt5_new_account';
    $mailbox->clear;
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'financial',
            mt5_account_type => 'standard',
            country          => 'mt',
            email            => $DETAILS{email},
            name             => $DETAILS{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $DETAILS{password},
            leverage         => 500,
        },
    };
    $c->call_ok($method, $params)->has_error('error for financial mt5_new_account')
        ->error_code_is('TINDetailsMandatory', 'tax information is mandatory for financial account');

    $test_client->tax_residence('mt');
    $test_client->tax_identification_number('111222333');
    $test_client->save;

    $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account');
    #check inbox for emails
    my $cli_subject  = 'Authenticate your account to continue trading on MT5';
    my @client_email = $mailbox->search(
        email   => $DETAILS{email},
        subject => qr/\Q$cli_subject\E/
    );

    ok(!@client_email, "identity verification request email not sent");
};

subtest 'new CR financial accounts should receive identity verification request if account is not verified' => sub {
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $test_client->set_authentication('ID_DOCUMENT')->status('pending');
    $test_client->save;
    my $method = 'mt5_new_account';
    $mailbox->clear;
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'financial',
            mt5_account_type => 'advanced',
            country          => 'mt',
            email            => $DETAILS{email},
            name             => $DETAILS{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $DETAILS{password},
            leverage         => 500,
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account');
    #check inbox for emails
    my $cli_subject  = 'Authenticate your account to continue trading on MT5';
    my @client_email = $mailbox->search(
        email   => $DETAILS{email},
        subject => qr/\Q$cli_subject\E/
    );

    ok(@client_email, "identity verification request email received");
};

subtest 'MF should be allowed' => sub {
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    my $mf_client = create_client('MF');
    $mf_client->set_default_account('EUR');
    $mf_client->save();
    $user->add_client($mf_client);

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'financial',
            mt5_account_type => 'standard',
            country          => 'es',
            email            => $DETAILS{email},
            name             => $DETAILS{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $DETAILS{password},
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account');
};

subtest 'MF to MLT account switching' => sub {
    my $mf_switch_client = create_client('MF');
    $mf_switch_client->set_default_account('EUR');
    $mf_switch_client->residence('at');

    my $mlt_switch_client = create_client('MLT');
    $mlt_switch_client->set_default_account('EUR');
    $mlt_switch_client->residence('at');

    $mf_switch_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});

    $mf_switch_client->save();
    $mlt_switch_client->save();

    my $switch_user = BOM::User->create(
        email    => 'switch@binary.com',
        password => 's3kr1t',
    );

    $switch_user->add_client($mf_switch_client);

    my $mf_switch_token = $m->create_token($mf_switch_client->loginid, 'test token');

    # we should get an error if we are trying to open a gaming account

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $mf_switch_token,
        args     => {
            account_type   => 'gaming',
            country        => 'es',
            email          => $DETAILS{email},
            name           => $DETAILS{name},
            investPassword => 'Abcd1234',
            mainPassword   => $DETAILS{password},
        },
    };

    BOM::RPC::v3::MT5::Account::reset_throttler($mf_switch_client->loginid);
    $c->call_ok($method, $params)->has_error('cannot create gaming account for MF only users')
        ->error_code_is('PermissionDenied', 'error should be permission denied');

    # add MLT client
    $switch_user->add_client($mlt_switch_client);

    BOM::RPC::v3::MT5::Account::reset_throttler($mlt_switch_client->loginid);
    $c->call_ok($method, $params)->has_no_error('gaming account should be created');
    is($c->result->{account_type}, 'gaming', 'account type should be gaming');

    # MF client should be allowed to open financial account as well
    $params->{args}->{account_type}     = 'financial';
    $params->{args}->{mt5_account_type} = 'standard';

    BOM::RPC::v3::MT5::Account::reset_throttler($mf_switch_client->loginid);
    BOM::RPC::v3::MT5::Account::reset_throttler($mlt_switch_client->loginid);

    $c->call_ok($method, $params)->has_no_error('standard account should be created');
    is($c->result->{account_type}, 'financial', 'account type should be financial');
};

subtest 'MLT to MF account switching' => sub {
    my $mf_switch_client = create_client('MF');
    $mf_switch_client->set_default_account('EUR');
    $mf_switch_client->residence('at');

    my $mlt_switch_client = create_client('MLT');
    $mlt_switch_client->set_default_account('EUR');
    $mlt_switch_client->residence('at');

    $mf_switch_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});

    $mf_switch_client->save();
    $mlt_switch_client->save();

    my $switch_user = BOM::User->create(
        email    => 'switch2@binary.com',
        password => 's3kr1t',
    );

    $switch_user->add_client($mlt_switch_client);

    my $mlt_switch_token = $m->create_token($mlt_switch_client->loginid, 'test token');

    # we should get an error if we are trying to open a financial account

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $mlt_switch_token,
        args     => {
            account_type     => 'financial',
            mt5_account_type => 'standard',
            country          => 'es',
            email            => $DETAILS{email},
            name             => $DETAILS{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $DETAILS{password},
        },
    };

    BOM::RPC::v3::MT5::Account::reset_throttler($mf_switch_client->loginid);
    $c->call_ok($method, $params)->has_error('cannot create financial account for MLT only users')
        ->error_code_is('PermissionDenied', 'error should be permission denied');

    # add MF client
    $switch_user->add_client($mf_switch_client);

    BOM::RPC::v3::MT5::Account::reset_throttler($mf_switch_client->loginid);
    $c->call_ok($method, $params)->has_no_error('financial account should be created');
    is($c->result->{account_type}, 'financial', 'account type should be financial');

    # MLT client should be allowed to open gaming account as well
    $params->{args}->{account_type}     = 'gaming';
    $params->{args}->{mt5_account_type} = undef;

    BOM::RPC::v3::MT5::Account::reset_throttler($mf_switch_client->loginid);
    BOM::RPC::v3::MT5::Account::reset_throttler($mlt_switch_client->loginid);

    $c->call_ok($method, $params)->has_no_error('gaming account should be created');
    is($c->result->{account_type}, 'gaming', 'account type should be gaming');
};

subtest 'get settings' => sub {
    my $method = 'mt5_get_settings';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login => $DETAILS{login},
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_get_settings');
    is($c->result->{login},   $DETAILS{login},   'result->{login}');
    is($c->result->{balance}, $DETAILS{balance}, 'result->{balance}');
    is($c->result->{country}, "mt",              'result->{country}');

    $params->{args}{login} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_get_settings wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_get_settings wrong login');
};

subtest 'login list' => sub {
    my $method = 'mt5_login_list';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {},
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_login_list');
    is_deeply(
        $c->result,
        [{
                login      => $DETAILS{login},
                email      => $DETAILS{email},
                group      => $DETAILS{group},
                balance    => $DETAILS{balance},
                name       => 'Test',
                country    => 'mt',
                currency   => 'USD',
                manager_id => '',
                status     => 0,
                company    => undef,
                leverage   => undef,
            }
        ],
        'mt5_login_list result'
    );
};

subtest 'password check' => sub {
    my $method = 'mt5_password_check';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login    => $DETAILS{login},
            password => $DETAILS{password},
            type     => 'main',
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_check');

    $params->{args}{password} = "wrong";
    $c->call_ok($method, $params)->has_error('error for mt5_password_check wrong password')
        ->error_code_is('MT5PasswordCheckError', 'error code for mt5_password_check wrong password');

    $params->{args}{login} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_password_check wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_password_check wrong login');
};

subtest 'password change' => sub {
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    my $method = 'mt5_password_change';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login         => $DETAILS{login},
            old_password  => $DETAILS{password},
            new_password  => 'Ijkl6789',
            password_type => 'main'
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_change');
    # This call yields a truth integer directly, not a hash
    is($c->result, 1, 'result');

    $params->{args}{login} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_password_change wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_password_change wrong login');

    # reset throller, test for password limit
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $params->{args}->{login}        = $DETAILS{login};
    $params->{args}->{old_password} = $DETAILS{password};
    $params->{args}->{new_password} = 'Ijkl6789';
    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_change');
    is($c->result, 1, 'result');

    $c->call_ok($method, $params)->has_error('error for mt5_password_change wrong login');
    is($c->result->{error}->{message_to_client}, 'Request too frequent. Please try again later.', 'change password hits rate limit');
};

subtest 'password reset' => sub {
    my $method = 'mt5_password_reset';
    $mailbox->clear;

    my $code = BOM::Platform::Token->new({
            email       => $DETAILS{email},
            expires_in  => 3600,
            created_for => 'mt5_password_reset'
        })->token;

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login             => $DETAILS{login},
            new_password      => 'Ijkl6789',
            password_type     => 'main',
            verification_code => $code
        }};

    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_change');
    # This call yields a truth integer directly, not a hash
    is($c->result, 1, 'result');

    my $subject = 'Your MT5 password has been reset.';
    my @msgs    = $mailbox->search(
        email   => $DETAILS{email},
        subject => qr/\Q$subject\E/
    );
    ok(@msgs, "email received");

};

subtest 'investor password reset' => sub {
    my $method = 'mt5_password_reset';
    $mailbox->clear;

    my $code = BOM::Platform::Token->new({
            email       => $DETAILS{email},
            expires_in  => 3600,
            created_for => 'mt5_password_reset'
        })->token;

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login             => $DETAILS{login},
            new_password      => 'Abcd1234',
            password_type     => 'investor',
            verification_code => $code
        }};

    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_change');
    # This call yields a truth integer directly, not a hash
    is($c->result, 1, 'result');

    my $subject = 'Your MT5 password has been reset.';
    my @msgs    = $mailbox->search(
        email   => $DETAILS{email},
        subject => qr/\Q$subject\E/
    );
    ok(@msgs, "email received");

};

subtest 'password check investor' => sub {
    my $method = 'mt5_password_check';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login         => $DETAILS{login},
            password      => 'Abcd1234',
            password_type => 'investor'
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_check');
};

subtest 'deposit' => sub {
    # User needs some real money now
    top_up $test_client, USD => 1000;

    my $method = "mt5_deposit";
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_binary => $test_client->loginid,
            to_mt5      => $DETAILS{login},
            amount      => 180,
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $c->call_ok($method, $params)->has_no_error('no error for mt5_deposit');
    ok(defined $c->result->{binary_transaction_id}, 'result has a transaction ID');
    subtest record_mt5_transfer_deposit => sub {
        my $mt5_transfer = _get_mt5transfer_from_transaction($test_client->db->dbic, $c->result->{binary_transaction_id});
        is($mt5_transfer->{mt5_amount}, -180, 'Correct amount recorded');
    };
    # assert that account balance is now 1000-180 = 820
    cmp_ok $test_client->default_account->balance, '==', 820, "Correct balance after deposited to mt5 account";

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $runtime_system->suspend->mt5_deposits(1);
    $c->call_ok($method, $params)->has_error('error as mt5_deposits are suspended in system config')
        ->error_code_is('MT5DepositError', 'error code is MT5DepositError')->error_message_is('Deposits are suspended.');
    $runtime_system->suspend->mt5_deposits(0);

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $params->{args}{to_mt5} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_deposit wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_deposit wrong login');
};

subtest 'mx_deposit' => sub {
    my $test_mx_client = create_client('MX');
    $test_mx_client->account('USD');
    $test_mx_client->email($DETAILS{email});
    $test_mx_client->save();

    $user->add_client($test_mx_client);

    my $token_mx = $m->create_token($test_mx_client->loginid, 'test token');

    my $params_mx = {
        language => 'EN',
        token    => $token_mx,
        args     => {
            from_binary => $test_mx_client->loginid,
            to_mt5      => $DETAILS{login},
            amount      => 180,
        },
    };

    my $method = "mt5_deposit";

    BOM::RPC::v3::MT5::Account::reset_throttler($test_mx_client->loginid);

    $c->call_ok($method, $params_mx)->has_error('Cannot access MT5 as MX')
        ->error_code_is('MT5DepositError', 'Transfers to MT5 not allowed error_code')
        ->error_message_is('There was an error processing the request. Please switch to your MF account to access MT5.');
};

subtest 'mx_withdrawal' => sub {
    my $test_mx_client = create_client('MX');
    $test_mx_client->account('USD');
    $test_mx_client->email($DETAILS{email});
    $test_mx_client->save();

    $user->add_client($test_mx_client);

    my $token_mx = $m->create_token($test_mx_client->loginid, 'test token');

    my $params_mx = {
        language => 'EN',
        token    => $token_mx,
        args     => {
            from_mt5  => $DETAILS{login},
            to_binary => $test_mx_client->loginid,
            amount    => 350,
        },
    };

    my $method = "mt5_withdrawal";

    BOM::RPC::v3::MT5::Account::reset_throttler($test_mx_client->loginid);

    $c->call_ok($method, $params_mx)->has_error('Cannot access MT5 as MX')->error_code_is('MT5WithdrawalError', 'error code is MT5WithdrawalError')
        ->error_message_is('There was an error processing the request. Please switch to your MF account to access MT5.');
};

subtest 'withdrawal' => sub {
    # TODO(leonerd): assertions in here about balance amounts would be
    #   sensitive to results of the previous test of mt5_deposit.
    my $method = "mt5_withdrawal";
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_mt5  => $DETAILS{login},
            to_binary => $test_client->loginid,
            amount    => 150,
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $c->call_ok($method, $params)->has_no_error('no error for mt5_withdrawal');
    ok(defined $c->result->{binary_transaction_id}, 'result has a transaction ID');

    cmp_ok $test_client->default_account->balance, '==', 820 + 150, "Correct balance after withdrawal";

    subtest record_mt5_transfer_withdrawal => sub {
        my $mt5_transfer = _get_mt5transfer_from_transaction($test_client->db->dbic, $c->result->{binary_transaction_id});

        is($mt5_transfer->{mt5_amount}, 150, 'Correct amount recorded');
    };
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $runtime_system->suspend->mt5_withdrawals(1);
    $c->call_ok($method, $params)->has_error('error as mt5_withdrawals are suspended in system config')
        ->error_code_is('MT5WithdrawalError', 'error code is MT5WithdrawalError')->error_message_is('Withdrawals are suspended.');
    $runtime_system->suspend->mt5_withdrawals(0);

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $params->{args}{from_mt5} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_withdrawal wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_withdrawal wrong login');
};

subtest 'mf_withdrawal' => sub {

    my $test_mf_client = create_client('MF');
    $test_mf_client->account('USD');

    $test_mf_client->email($DETAILS{email});
    $test_mf_client->status->clear_age_verification;

    $_->delete for @{$test_mf_client->client_authentication_method};
    $test_mf_client->save();

    $user->add_client($test_mf_client);

    my $token_mf = $m->create_token($test_mf_client->loginid, 'test token');

    my $params_mf = {
        language => 'EN',
        token    => $token_mf,
        args     => {
            from_mt5  => $DETAILS{login},
            to_binary => $test_mf_client->loginid,
            amount    => 350,
        },
    };

    BOM::RPC::v3::MT5::Account::reset_throttler($test_mf_client->loginid);

    my $method = "mt5_withdrawal";

    $c->call_ok($method, $params_mf)->has_error('Withdrawal request failed.')
        ->error_code_is('MT5WithdrawalError', 'error code is MT5WithdrawalError')
        ->error_message_is('There was an error processing the request. Please authenticate your account.');

    $test_mf_client->set_authentication('ID_DOCUMENT')->status('pass');
    $test_mf_client->save();

    BOM::RPC::v3::MT5::Account::reset_throttler($test_mf_client->loginid);

    $c->call_ok($method, $params_mf)->has_no_error('no error for mt5_withdrawal');

    cmp_ok $test_mf_client->default_account->balance, '==', 350, "Correct balance after withdrawal";
};

subtest 'mf_deposit' => sub {

    my $test_mf_client = create_client('MF');
    $test_mf_client->account('USD');
    top_up $test_mf_client, USD => 1000;

    $test_mf_client->email($DETAILS{email});
    $test_mf_client->status->clear_age_verification;

    $_->delete for @{$test_mf_client->client_authentication_method};
    $test_mf_client->save();

    $user->add_client($test_mf_client);

    my $token_mf = $m->create_token($test_mf_client->loginid, 'test token');

    my $params_mf = {
        language => 'EN',
        token    => $token_mf,
        args     => {
            from_binary => $test_mf_client->loginid,
            to_mt5      => $DETAILS{login},
            amount      => 350,
        },
    };

    BOM::RPC::v3::MT5::Account::reset_throttler($test_mf_client->loginid);

    my $method = "mt5_deposit";

    $c->call_ok($method, $params_mf)->has_error('Deposit request failed.')->error_code_is('MT5DepositError', 'error code is MT5DepositError')
        ->error_message_is('There was an error processing the request. Please authenticate your account.');

    $test_mf_client->set_authentication('ID_DOCUMENT')->status('pass');
    $test_mf_client->save();

    BOM::RPC::v3::MT5::Account::reset_throttler($test_mf_client->loginid);

    $c->call_ok($method, $params_mf)->has_no_error('no error for mt5_deposit');

    cmp_ok $test_mf_client->default_account->balance, '==', 650, "Correct balance after deposit";
};

subtest 'multi currency transfers' => sub {
    my $client_eur = create_client('CR');
    my $client_btc = create_client('CR');
    my $client_ust = create_client('CR');
    $client_eur->set_default_account('EUR');
    $client_btc->set_default_account('BTC');
    $client_ust->set_default_account('UST');
    top_up $client_eur, EUR => 1000;
    top_up $client_btc, BTC => 1;
    top_up $client_ust, UST => 1000;
    $user->add_client($client_eur);
    $user->add_client($client_btc);
    $user->add_client($client_ust);

    my $eur_test_amount = 100;
    my $btc_test_amount = 0.1;
    my $ust_test_amount = 100;
    my $usd_test_amount = 100;

    my $deposit_params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_binary => $client_eur->loginid,
            to_mt5      => $DETAILS{login},
            amount      => $eur_test_amount,
        },
    };

    my $withdraw_params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_mt5  => $DETAILS{login},
            to_binary => $client_eur->loginid,
            amount    => $usd_test_amount,
        },
    };

    my $prev_bal;
    my ($EUR_USD, $BTC_USD, $UST_USD) = (1.1, 5000, 1);

    my ($eur_usd_fee, $btc_usd_fee, $ust_usd_fee) = (0.02, 0.03, 0.04);

    my $after_fiat_fee   = 1 - $eur_usd_fee;
    my $after_crypto_fee = 1 - $btc_usd_fee;
    my $after_stable_fee = 1 - $ust_usd_fee;

    BOM::Config::Runtime->instance->app_config->set({
            'payments.transfer_between_accounts.fees.by_currency' => JSON::MaybeUTF8::encode_json_utf8({
                    "EUR_USD" => $eur_usd_fee * 100,
                    "USD_EUR" => $eur_usd_fee * 100,
                    "BTC_USD" => $btc_usd_fee * 100,
                    "USD_BTC" => $btc_usd_fee * 100,
                    "UST_USD" => $ust_usd_fee * 100,
                    "USD_UST" => $ust_usd_fee * 100
                })});

    subtest 'EUR tests' => sub {
        $manager_module->mock(
            'deposit',
            sub {
                is financialrounding('amount', 'USD', shift->{amount}),
                    financialrounding('amount', 'USD', $eur_test_amount * $EUR_USD * $after_fiat_fee),
                    'Correct forex fee for USD<->EUR';
                return Future->done({success => 1});
            });

        $redis->hmset(
            'exchange_rates::EUR_USD',
            quote => $EUR_USD,
            epoch => time
        );

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_deposit', $deposit_params)->has_no_error('deposit EUR->USD with current rate - no error');
        ok(defined $c->result->{binary_transaction_id}, 'deposit EUR->USD with current rate - has transaction id');

        subtest multicurrency_mt5_transfer_deposit => sub {
            my $mt5_transfer = _get_mt5transfer_from_transaction($test_client->db->dbic, $c->result->{binary_transaction_id});
            # (100Eur  * 1%(fee)) * 1.1(Exchange Rate) = 108.9
            is($mt5_transfer->{mt5_amount}, -100 * $after_fiat_fee * $EUR_USD, 'Correct amount recorded');
        };

        $prev_bal = $client_eur->account->balance;
        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_no_error('withdraw USD->EUR with current rate - no error');
        ok(defined $c->result->{binary_transaction_id}, 'withdraw USD->EUR with current rate - has transaction id');
        is financialrounding('amount', 'EUR', $client_eur->account->balance),
            financialrounding('amount', 'EUR', $prev_bal + ($usd_test_amount / $EUR_USD * $after_fiat_fee)),
            'Correct forex fee for USD<->EUR';

        subtest multicurrency_mt5_transfer_withdrawal => sub {
            my $mt5_transfer = _get_mt5transfer_from_transaction($test_client->db->dbic, $c->result->{binary_transaction_id});
            is($mt5_transfer->{mt5_amount}, 100, 'Correct amount recorded');
        };

        $redis->hmset(
            'exchange_rates::EUR_USD',
            quote => $EUR_USD,
            epoch => time - (3600 * 12));

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_deposit', $deposit_params)->has_no_error('deposit EUR->USD with 12hr old rate - no error');
        ok(defined $c->result->{binary_transaction_id}, 'deposit EUR->USD with 12hr old rate - has transaction id');

        $prev_bal = $client_eur->account->balance;
        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_no_error('withdraw USD->EUR with current rate - no error');
        ok(defined $c->result->{binary_transaction_id}, 'withdraw USD->EUR with 12hr old rate - has transaction id');
        is financialrounding('amount', 'EUR', $client_eur->account->balance),
            financialrounding('amount', 'EUR', $prev_bal + ($usd_test_amount / $EUR_USD * $after_fiat_fee)),
            'Correct forex fee for USD<->EUR';

        $redis->hmset(
            'exchange_rates::EUR_USD',
            quote => $EUR_USD,
            epoch => time - (3600 * 25));

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_deposit', $deposit_params)->has_error('deposit EUR->USD with >1 day old rate - has error')
            ->error_code_is('MT5DepositError', 'deposit EUR->USD with >1 day old rate - correct error code');

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_error('withdraw USD->EUR with >1 day old rate - has error')
            ->error_code_is('MT5WithdrawalError', 'withdraw USD->EUR with >1 day old rate - correct error code');
    };

    subtest 'BTC tests' => sub {

        $manager_module->mock(
            'deposit',
            sub {
                is financialrounding('amount', 'USD', shift->{amount}),
                    financialrounding('amount', 'USD', $btc_test_amount * $BTC_USD * $after_crypto_fee),
                    'Correct forex fee for USD<->BTC';
                return Future->done({success => 1});
            });

        $deposit_params->{args}->{from_binary} = $withdraw_params->{args}->{to_binary} = $client_btc->loginid;
        $deposit_params->{args}->{amount} = $btc_test_amount;

        $redis->hmset(
            'exchange_rates::BTC_USD',
            quote => $BTC_USD,
            epoch => time
        );

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_deposit', $deposit_params)->has_no_error('deposit BTC->USD with current rate - no error');
        ok(defined $c->result->{binary_transaction_id}, 'deposit BTC->USD with current rate - has transaction id');

        $prev_bal = $client_btc->account->balance;
        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_no_error('withdraw USD->BTC with current rate - no error');
        ok(defined $c->result->{binary_transaction_id}, 'withdraw USD->BTC with current rate - has transaction id');
        is financialrounding('amount', 'BTC', $client_btc->account->balance),
            financialrounding('amount', 'BTC', $prev_bal + ($usd_test_amount / $BTC_USD * $after_crypto_fee)),
            'Correct forex fee for USD<->BTC';

        $redis->hmset(
            'exchange_rates::BTC_USD',
            quote => $BTC_USD,
            epoch => time - 3595
        );

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_deposit', $deposit_params)->has_no_error('deposit BTC->USD with older rate <1 hour - no error');
        ok(defined $c->result->{binary_transaction_id}, 'deposit BTC->USD with older rate <1 hour - has transaction id');

        $prev_bal = $client_btc->account->balance;
        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_no_error('withdraw USD->BTC with older rate <1 hour - no error');
        ok(defined $c->result->{binary_transaction_id}, 'withdraw USD->BTC with older rate <1 hour - has transaction id');
        is financialrounding('amount', 'BTC', $client_btc->account->balance),
            financialrounding('amount', 'BTC', $prev_bal + ($usd_test_amount / $BTC_USD * $after_crypto_fee)),
            'Correct forex fee for USD<->BTC';

        $redis->hmset(
            'exchange_rates::BTC_USD',
            quote => $BTC_USD,
            epoch => time - 3605
        );

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_deposit', $deposit_params)->has_error('deposit BTC->USD with rate >1 hour old - has error')
            ->error_code_is('MT5DepositError', 'deposit BTC->USD with rate >1 hour old - correct error code');

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_error('withdraw USD->BTC with rate >1 hour old - has error')
            ->error_code_is('MT5WithdrawalError', 'withdraw USD->BTC with rate >1 hour old - correct error code');
    };

    subtest 'UST tests' => sub {

        $manager_module->mock(
            'deposit',
            sub {
                is financialrounding('amount', 'USD', shift->{amount}),
                    financialrounding('amount', 'USD', $ust_test_amount * $UST_USD * $after_stable_fee),
                    'Correct forex fee for USD<->UST';
                return Future->done({success => 1});
            });

        $deposit_params->{args}->{from_binary} = $withdraw_params->{args}->{to_binary} = $client_ust->loginid;
        $deposit_params->{args}->{amount} = $ust_test_amount;

        $redis->hmset(
            'exchange_rates::UST_USD',
            quote => $UST_USD,
            epoch => time
        );

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_deposit', $deposit_params)->has_no_error('deposit UST->USD with current rate - no error');
        ok(defined $c->result->{binary_transaction_id}, 'deposit UST->USD with current rate - has transaction id');

        $prev_bal = $client_ust->account->balance;
        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_no_error('withdraw USD->UST with current rate - no error');
        ok(defined $c->result->{binary_transaction_id}, 'withdraw USD->UST with current rate - has transaction id');
        is financialrounding('amount', 'UST', $client_ust->account->balance),
            financialrounding('amount', 'UST', $prev_bal + ($usd_test_amount / $UST_USD * $after_stable_fee)),
            'Correct forex fee for USD<->UST';

        $redis->hmset(
            'exchange_rates::UST_USD',
            quote => $UST_USD,
            epoch => time - 3595
        );

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_deposit', $deposit_params)->has_no_error('deposit UST->USD with older rate <1 hour - no error');
        ok(defined $c->result->{binary_transaction_id}, 'deposit UST->USD with older rate <1 hour - has transaction id');

        $prev_bal = $client_ust->account->balance;
        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_no_error('withdraw USD->UST with older rate <1 hour - no error');
        ok(defined $c->result->{binary_transaction_id}, 'withdraw USD->UST with older rate <1 hour - has transaction id');
        is financialrounding('amount', 'UST', $client_ust->account->balance),
            financialrounding('amount', 'UST', $prev_bal + ($usd_test_amount / $UST_USD * $after_stable_fee)),
            'Correct forex fee for USD<->UST';

        $redis->hmset(
            'exchange_rates::UST_USD',
            quote => $UST_USD,
            epoch => time - 3605
        );

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_deposit', $deposit_params)->has_error('deposit UST->USD with rate >1 hour old - has error')
            ->error_code_is('MT5DepositError', 'deposit UST->USD with rate >1 hour old - correct error code');

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_error('withdraw USD->UST with rate >1 hour old - has error')
            ->error_code_is('MT5WithdrawalError', 'withdraw USD->UST with rate >1 hour old - correct error code');
    };
    BOM::Config::Runtime->instance->app_config->set({'payments.transfer_between_accounts.fees.by_currency' => '{}'});
};

subtest 'Transfers Limits' => sub {
    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->MT5(0);
    my $client = create_client('CR');
    $client->set_default_account('USD');
    top_up $client, EUR => 1000;
    $user->add_client($client);

    my $deposit_params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_binary => $client->loginid,
            to_mt5      => $DETAILS{login},
            amount      => 1
        },
    };

    $c->call_ok('mt5_deposit', $deposit_params)->has_error('Transfers should have been stopped')
        ->error_code_is('MT5DepositError', 'Transfers limit - correct error code')
        ->error_message_is('There was an error processing the request. Maximum of 0 transfers allowed per day.',
        'Transfers limit - correct error message');

    # unlimit the transfers again
    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->MT5(999);
};

subtest 'Suspended Transfers Currencies' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies(['BTC']);
    my $client_cr_btc = create_client('CR');
    $client_cr_btc->set_default_account('BTC');
    top_up $client_cr_btc, BTC => 10;
    $user->add_client($client_cr_btc);

    subtest 'it should stop transfer from suspended currency' => sub {
        my $deposit_params = {
            language => 'EN',
            token    => $token,
            args     => {
                from_binary => $client_cr_btc->loginid,
                to_mt5      => $DETAILS{login},
                amount      => 1
            },
        };

        $c->call_ok('mt5_deposit', $deposit_params)->has_error('Transfers should have been stopped')
            ->error_code_is('MT5DepositError', 'Transfer from suspended currency not allowed - correct error code')
            ->error_message_is('There was an error processing the request. Account transfers are not available between BTC and USD',
            'Transfer from suspended currency not allowed - correct error message');

    };
    BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies([]);
};

sub _get_mt5transfer_from_transaction {
    my ($dbic, $transaction_id) = @_;

    my $result = $dbic->run(
        fixup => sub {
            $_->selectrow_hashref(
                "Select mt.* FROM payment.mt5_transfer mt JOIN transaction.transaction tt
                ON mt.payment_id = tt.payment_id where tt.id = ?",
                undef,
                $transaction_id,
            );
        });
    return $result;
}
done_testing();
