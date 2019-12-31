use strict;
use warnings;
use Guard;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use Test::MockTime qw(:all);
use JSON::MaybeUTF8;
use List::Util qw();
use Email::Address::UseXS;
use Format::Util::Numbers qw/financialrounding get_min_unit/;

use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Test::Email qw(:no_event);
use BOM::MT5::User::Async;
use BOM::Platform::Token;
use BOM::User;
use BOM::Config::Runtime;
use BOM::Config::RedisReplicated;
use BOM::Config::CurrencyConfig;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);
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

# Mocked MT5 account details
# %ACCOUNTS and %DETAILS are shared between four files, and should be kept in-sync to avoid test failures
#   t/BOM/RPC/30_mt5.t
#   t/BOM/RPC/05_accounts.t
#   t/BOM/RPC/Cashier/20_transfer_between_accounts.t
#   t/lib/mock_binary_mt5.pl

my %ACCOUNTS = (
    'demo\svg_standard'             => '00000001',
    'demo\svg_advanced'             => '00000002',
    'demo\labuan_standard'          => '00000003',
    'demo\labuan_advanced'          => '00000004',
    'real\malta'                    => '00000010',
    'real\maltainvest_standard'     => '00000011',
    'real\maltainvest_standard_GBP' => '00000012',
    'real\svg'                      => '00000013',
    'real\svg_standard'             => '00000014',
    'real\labuan_advanced'          => '00000015',
);

my %DETAILS = (
    password        => 'Efgh4567',
    email           => 'test.account@binary.com',
    name            => 'Meta traderman',
    group           => 'real\svg',
    country         => 'Malta',
    balance         => '1234',
    display_balance => '1234.00',
);

# Setup a test user
my $test_client    = create_client('CR');
my $test_client_vr = create_client('VRTC');

$test_client->email($DETAILS{email});
$test_client->set_default_account('USD');
$test_client->binary_user_id(1);

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

my %basic_details = (
    place_of_birth            => "af",
    tax_residence             => "af",
    tax_identification_number => "1122334455",
    account_opening_reason    => "testing"
);

$test_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
$test_client->save;

my $m        = BOM::Platform::Token::API->new;
my $token    = $m->create_token($test_client->loginid, 'test token');
my $token_vr = $m->create_token($test_client_vr->loginid, 'test token');

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

# Throttle function limits requests to 1 per minute which may cause
# consecutive tests to fail without a reset.
BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

subtest 'new account with invalid main password format' => sub {
    my $method                   = 'mt5_new_account';
    my $wrong_formatted_password = 'abc123';
    my $params                   = {
        language => 'EN',
        token    => $token,
        args     => {
            email            => $DETAILS{email},
            name             => $DETAILS{name},
            account_type     => "demo",
            address          => "Dummy address",
            city             => "Valletta",
            company          => "Binary Limited",
            country          => "mt",
            mainPassword     => "abc123",
            mt5_account_type => "standard",
            phone            => "+6123456789",
            phonePassword    => "AbcDv1234",
            state            => "Valleta",
            zipCode          => "VLT 1117",
            investPassword   => "AbcDv12345",
            mainPassword     => $wrong_formatted_password,
            leverage         => 100,
        },
    };

    $c->call_ok($method, $params)->has_error('error code for mt5_new_account wrong password formatting')
        ->error_code_is('IncorrectMT5PasswordFormat', 'error code for mt5_new_account wrong password formatting')
        ->error_message_like(qr/Your password must have/, 'error code for mt5_new_account wrong password formatting');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
};

subtest 'new account with missing signup fields' => sub {
    # only Labuan has the signup (phone) requirement

    $test_client->status->set('crs_tin_information', 'system', 'testing something');
    $test_client->phone('');
    $test_client->save;

    my $method = 'mt5_new_account';
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
            leverage         => 100,
        },
    };

    $c->call_ok($method, $params)->has_error('error from missing signup details')
        ->error_code_is('ASK_FIX_DETAILS', 'error code for missing basic details')
        ->error_details_is({missing => ['phone']}, 'missing field in response details');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $test_client->status->clear_crs_tin_information;
    $test_client->phone('12345678');
    $test_client->save;
};

subtest 'new account' => sub {
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            country      => 'mt',
            email        => $DETAILS{email},
            name         => $DETAILS{name},
            mainPassword => $DETAILS{password},
            leverage     => 100,
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account without investPassword');
    is($c->result->{login},           $ACCOUNTS{'real\svg'}, 'result->{login}');
    is($c->result->{balance},         0,                     'Balance is 0 upon creation');
    is($c->result->{display_balance}, '0.00',                'Display balance is "0.00" upon creation');

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
        ->error_code_is('MT5CreateUserError', 'error code for duplicate mt5_new_account')
        ->error_message_like(qr/account already exists/, 'error message for duplicate mt5_new_account');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
};

subtest 'MF should be allowed' => sub {
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    my $mf_client = create_client('MF');
    $mf_client->set_default_account('EUR');
    $mf_client->$_($basic_details{$_}) for keys %basic_details;
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

    $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account for financial standard with no tax information');

    $test_client->tax_residence('mt');
    $test_client->tax_identification_number('111222333');
    $test_client->save;
};

subtest 'MF to MLT account switching' => sub {
    my $mf_switch_client = create_client('MF');
    $mf_switch_client->set_default_account('EUR');
    $mf_switch_client->residence('at');
    $mf_switch_client->account_opening_reason('speculative');

    my $mlt_switch_client = create_client('MLT');
    $mlt_switch_client->set_default_account('EUR');
    $mlt_switch_client->residence('at');
    $mlt_switch_client->account_opening_reason('speculative');

    $mf_switch_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
    $mf_switch_client->$_($basic_details{$_}) for keys %basic_details;

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
        ->error_code_is('GamingAccountMissing', 'error should be missing gaming account');

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
    $mf_switch_client->tax_residence('at');
    $mf_switch_client->tax_identification_number('1234');
    $mf_switch_client->account_opening_reason('speculative');

    my $mlt_switch_client = create_client('MLT');
    $mlt_switch_client->set_default_account('EUR');
    $mlt_switch_client->residence('at');

    $mf_switch_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
    $mlt_switch_client->$_($basic_details{$_}) for keys %basic_details;

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
        ->error_code_is('FinancialAccountMissing', 'error should be financial account missing');

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

subtest 'VRTC to MLT and MF account switching' => sub {
    my $mf_switch_client = create_client('MF');
    $mf_switch_client->set_default_account('GBP');
    $mf_switch_client->residence('at');
    $mf_switch_client->tax_residence('at');
    $mf_switch_client->tax_identification_number('1234');
    $mf_switch_client->account_opening_reason('speculative');

    my $mlt_switch_client = create_client('MLT');
    $mlt_switch_client->set_default_account('EUR');
    $mlt_switch_client->residence('at');

    my $vr_switch_client = create_client('VRTC');
    $vr_switch_client->set_default_account('USD');
    $vr_switch_client->residence('at');

    $mf_switch_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
    $mlt_switch_client->$_($basic_details{$_}) for keys %basic_details;

    $mf_switch_client->save();
    $mlt_switch_client->save();
    $vr_switch_client->save();

    my $switch_user = BOM::User->create(
        email    => 'switch+vrtc@binary.com',
        password => 's3kr1t',
    );

    $switch_user->add_client($vr_switch_client);

    my $vr_switch_token = $m->create_token($vr_switch_client->loginid, 'test token');

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $vr_switch_token,
        args     => {
            account_type   => 'gaming',
            country        => 'es',
            email          => $DETAILS{email},
            name           => $DETAILS{name},
            investPassword => 'Abcd1234',
            mainPassword   => $DETAILS{password},
        },
    };

    BOM::RPC::v3::MT5::Account::reset_throttler($mlt_switch_client->loginid);
    $c->call_ok($method, $params)->has_error('cannot create gaming account for VRTC only users')
        ->error_code_is('RealAccountMissing', 'error should be permission denied');

    $switch_user->add_client($mlt_switch_client);

    $c->call_ok($method, $params)->has_no_error('gaming account should be created');
    is($c->result->{account_type}, 'gaming', 'account type should be gaming');

    # we should get an error if we are trying to open a financial account

    $method = 'mt5_new_account';
    $params = {
        language => 'EN',
        token    => $vr_switch_token,
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
        ->error_code_is('FinancialAccountMissing', 'error should be permission denied');

    # add MF client
    $switch_user->add_client($mf_switch_client);

    BOM::RPC::v3::MT5::Account::reset_throttler($mf_switch_client->loginid);
    $c->call_ok($method, $params)->has_no_error('financial account should be created');
    is($c->result->{account_type}, 'financial', 'account type should be financial');
};

subtest 'get settings' => sub {
    my $method = 'mt5_get_settings';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login => $ACCOUNTS{'real\svg'},
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_get_settings');
    is($c->result->{login},   $ACCOUNTS{'real\svg'}, 'result->{login}');
    is($c->result->{balance}, $DETAILS{balance},     'result->{balance}');
    is($c->result->{country}, "mt",                  'result->{country}');

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

    my @accounts = map { $_->{login} } @{$c->result};
    cmp_bag(\@accounts, [$ACCOUNTS{'real\svg'}, $ACCOUNTS{'real\svg_standard'}], "mt5_login_list result");
};

subtest 'login list partly successfull result' => sub {
    my $bom_user_mock = Test::MockModule->new('BOM::User');
    $bom_user_mock->mock('mt5_logins', sub { return qw(MT00000013 MT00000014) });

    my $mt5_acc_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mt5_acc_mock->mock(
        'mt5_get_settings',
        sub {
            my $login = shift->{args}{login};

            #result one login should have error msg
            return BOM::RPC::v3::MT5::Account::create_error_future('General') if $login eq '00000014';

            return Future->done({some => 'valid data'});
        });

    my $method = 'mt5_login_list';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {},
    };

    $c->call_ok($method, $params)->has_error('has error for mt5_login_list')->error_code_is('General', 'Should return correct error code');
};

subtest 'login list without success results' => sub {
    my $bom_user_mock = Test::MockModule->new('BOM::User');
    $bom_user_mock->mock('mt5_logins', sub { return qw(MT00000013 MT00000014) });

    my $mt5_acc_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mt5_acc_mock->mock(
        'mt5_get_settings',
        sub {
            BOM::RPC::v3::MT5::Account::create_error_future('General');
        });

    my $method = 'mt5_login_list';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {},
    };

    $c->call_ok($method, $params)->has_error('has error for mt5_login_list')->error_code_is('General', 'Should return correct error code');
};

subtest 'create new account fails, when we get error during getting login list' => sub {
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

    my $bom_user_mock = Test::MockModule->new('BOM::User');
    $bom_user_mock->mock('mt5_logins', sub { return qw(MT00000013 MT00000014) });

    my $mt5_acc_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mt5_acc_mock->mock(
        'mt5_get_settings',
        sub {
            BOM::RPC::v3::MT5::Account::create_error_future('General');
        });

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $c->call_ok($method, $params)->has_error('has error for mt5_login_list')->error_code_is('General', 'Should return correct error code');
};

subtest 'password check' => sub {
    my $method = 'mt5_password_check';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login    => $ACCOUNTS{'real\svg'},
            password => $DETAILS{password},
            type     => 'main',
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_check');

    $params->{args}{password} = "wrong";
    $c->call_ok($method, $params)->has_error('error for mt5_password_check wrong password')
        ->error_message_like(qr/Forgot your password/, 'error code for mt5_password_check wrong password');

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
            login         => $ACCOUNTS{'real\svg'},
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
    $params->{args}->{login}        = $ACCOUNTS{'real\svg'};
    $params->{args}->{old_password} = $DETAILS{password};
    $params->{args}->{new_password} = 'Ijkl6789';
    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_change');
    is($c->result, 1, 'result');

    $c->call_ok($method, $params)->has_error('error for mt5_password_change wrong login');
    is(
        $c->result->{error}->{message_to_client},
        'It looks like you have already made the request. Please try again later.',
        'change password hits rate limit'
    );
};

subtest 'password reset' => sub {
    my $method = 'mt5_password_reset';
    mailbox_clear();

    my $code = BOM::Platform::Token->new({
            email       => $DETAILS{email},
            expires_in  => 3600,
            created_for => 'mt5_password_reset'
        })->token;

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login             => $ACCOUNTS{'real\svg'},
            new_password      => 'Ijkl6789',
            password_type     => 'main',
            verification_code => $code
        }};

    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_change');
    # This call yields a truth integer directly, not a hash
    is($c->result, 1, 'result');

    my $subject = 'Your MT5 password has been reset.';
    my $msg     = mailbox_search(
        email   => $DETAILS{email},
        subject => qr/\Q$subject\E/
    );
    ok($msg, "email received");

};

subtest 'investor password reset' => sub {
    my $method = 'mt5_password_reset';
    mailbox_clear();

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return 'svg' });

    my $code = BOM::Platform::Token->new({
            email       => $DETAILS{email},
            expires_in  => 3600,
            created_for => 'mt5_password_reset'
        })->token;

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login             => $ACCOUNTS{'real\svg'},
            new_password      => 'Abcd1234',
            password_type     => 'investor',
            verification_code => $code
        }};

    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_change');
    # This call yields a truth integer directly, not a hash
    is($c->result, 1, 'result');

    my $subject = 'Your MT5 password has been reset.';
    my $msg     = mailbox_search(
        email   => $DETAILS{email},
        subject => qr/\Q$subject\E/
    );
    ok($msg, "email received");

    $demo_account_mock->unmock;
};

subtest 'password check investor' => sub {
    my $method = 'mt5_password_check';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login         => $ACCOUNTS{'real\svg'},
            password      => 'Abcd1234',
            password_type => 'investor'
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_check');
};

subtest 'deposit' => sub {
    # User needs some real money now
    top_up $test_client, USD => 1000;

    my $loginid = $test_client->loginid;

    my $method = "mt5_deposit";
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_binary => $loginid,
            to_mt5      => $ACCOUNTS{'real\svg'},
            amount      => 180,
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return 'svg' });

    BOM::RPC::v3::MT5::Account::reset_throttler($loginid);
    $c->call_ok($method, $params)->has_no_error('no error for mt5_deposit');
    ok(defined $c->result->{binary_transaction_id}, 'result has a transaction ID');
    subtest record_mt5_transfer_deposit => sub {
        my $mt5_transfer = _get_mt5transfer_from_transaction($test_client->db->dbic, $c->result->{binary_transaction_id});
        is($mt5_transfer->{mt5_amount}, -180, 'Correct amount recorded');
    };
    # assert that account balance is now 1000-180 = 820
    cmp_ok $test_client->default_account->balance, '==', 820, "Correct balance after deposited to mt5 account";

    BOM::RPC::v3::MT5::Account::reset_throttler($loginid);

    $runtime_system->mt5->suspend->deposits(1);
    $c->call_ok($method, $params)->has_error('error as mt5_deposits are suspended in system config')
        ->error_code_is('MT5DepositError', 'error code is MT5DepositError')
        ->error_message_is('Deposits are currently unavailable. Please try again later.');
    $runtime_system->mt5->suspend->deposits(0);

    BOM::RPC::v3::MT5::Account::reset_throttler($loginid);

    $test_client->status->set('no_withdrawal_or_trading', 'system', 'pending investigations');
    $c->call_ok($method, $params)->has_error('client is blocked from withdrawal')->error_code_is('MT5DepositError', 'error code is MT5DepositError')
        ->error_message_is('You cannot perform this action, as your account is withdrawal locked.');
    $test_client->status->clear_no_withdrawal_or_trading;

    BOM::RPC::v3::MT5::Account::reset_throttler($loginid);

    $params->{args}{to_mt5} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_deposit wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_deposit wrong login');

    $demo_account_mock->unmock;
};

subtest 'demo account can not be tagged as an agent' => sub {
    my $method            = 'mt5_new_account';
    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_get_mt5_account_from_affiliate_token', sub { return '1234' });
    $test_client->myaffiliates_token("asdfas");
    $test_client->save;

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'demo',
            mt5_account_type => 'standard',
            country          => 'af',
            email            => $DETAILS{email},
            name             => $DETAILS{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $DETAILS{password},
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account');
    is($c->result->{agent}, undef, 'Agent should not be tagged for demo account');
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $test_client->myaffiliates_token("");
    $test_client->save;
};

subtest 'virtual_deposit' => sub {

    my $method = "mt5_new_account";
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    my $new_account_params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'demo',
            mt5_account_type => 'advanced',
            country          => 'af',
            email            => $DETAILS{email},
            name             => $DETAILS{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $DETAILS{password},
        },
    };

    $c->call_ok($method, $new_account_params)->has_no_error('no error for mt5_new_account');
    is($c->result->{balance},         10000,      'Balance is 10,000 upon creation');
    is($c->result->{display_balance}, '10000.00', 'Display balance is "10000.00" upon creation');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_is_account_demo', sub { return 1 });
    $demo_account_mock->mock('_fetch_mt5_lc',    sub { return 'iom' });

    $method = "mt5_deposit";
    my $deposit_demo_params = {
        language => 'EN',
        token    => $token,
        args     => {
            to_mt5 => $ACCOUNTS{'real\svg'},
            amount => 180,
        },
    };

    $c->call_ok($method, $deposit_demo_params)->has_error('Cannot Deposit')->error_code_is('MT5DepositError')
        ->error_message_like(qr/balance falls below USD 1000.00/, 'Balance is higher');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $demo_account_mock->unmock;

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
            to_mt5      => $ACCOUNTS{'real\svg'},
            amount      => 180,
        },
    };

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return 'maltainvest' });

    my $method = "mt5_deposit";

    BOM::RPC::v3::MT5::Account::reset_throttler($test_mx_client->loginid);

    $c->call_ok($method, $params_mx)->has_error('Cannot access MT5 as MX')
        ->error_code_is('MT5DepositError', 'Transfers to MT5 not allowed error_code')->error_message_like(qr/not allow MT5 trading/);
    $demo_account_mock->unmock;
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
            from_mt5  => $ACCOUNTS{'real\svg'},
            to_binary => $test_mx_client->loginid,
            amount    => 350,
        },
    };

    my $method = "mt5_withdrawal";

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return 'maltainvest' });

    BOM::RPC::v3::MT5::Account::reset_throttler($test_mx_client->loginid);

    $c->call_ok($method, $params_mx)->has_error('Cannot access MT5 as MX')->error_code_is('MT5WithdrawalError', 'error code is MT5WithdrawalError')
        ->error_message_like(qr/not allow MT5 trading/);
    $demo_account_mock->unmock;
};

subtest 'withdrawal' => sub {
    # TODO(leonerd): assertions in here about balance amounts would be
    #   sensitive to results of the previous test of mt5_deposit.
    my $method = "mt5_withdrawal";
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_mt5  => $ACCOUNTS{'real\svg'},
            to_binary => $test_client_vr->loginid,
            amount    => 150,
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return 'svg' });

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $c->call_ok($method, $params)->has_error('cannot withdrawals to virtual account')
        ->error_message_is('You cannot perform this action with a virtual account.');

    $params->{args}->{to_binary} = $test_client->loginid;
    $params->{token} = $token_vr;
    $c->call_ok($method, $params)->has_error('fail withdrawals with vr_token')->error_code_is('PermissionDenied', 'error code is PermissionDenied');
    $params->{token} = $token;

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $c->call_ok($method, $params)->has_no_error('no error for mt5_withdrawal');
    ok(defined $c->result->{binary_transaction_id}, 'result has a transaction ID');

    cmp_ok $test_client->default_account->balance, '==', 820 + 150, "Correct balance after withdrawal";

    subtest record_mt5_transfer_withdrawal => sub {
        my $mt5_transfer = _get_mt5transfer_from_transaction($test_client->db->dbic, $c->result->{binary_transaction_id});

        is($mt5_transfer->{mt5_amount}, 150, 'Correct amount recorded');
    };
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $runtime_system->mt5->suspend->withdrawals(1);
    $c->call_ok($method, $params)->has_error('error as mt5_withdrawals are suspended in system config')
        ->error_code_is('MT5WithdrawalError', 'error code is MT5WithdrawalError')
        ->error_message_is('Withdrawals are currently unavailable. Please try again later.');
    $runtime_system->mt5->suspend->withdrawals(0);

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $params->{args}{from_mt5} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_withdrawal wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_withdrawal wrong login');

    $demo_account_mock->unmock;
};

subtest 'labuan withdrawal' => sub {
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'financial',
            mt5_account_type => 'advanced',
            country          => 'af',
            email            => $DETAILS{email},
            name             => $DETAILS{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $DETAILS{password},
        },
    };

    $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account without investPassword');
    is($c->result->{login},           $ACCOUNTS{'real\labuan_advanced'}, 'result->{login}');
    is($c->result->{balance},         0,                                 'Balance is 0 upon creation');
    is($c->result->{display_balance}, '0.00',                            'Display balance is "0.00" upon creation');

    $test_client->financial_assessment({data => '{}'});
    $test_client->save();

    $method = "mt5_withdrawal";
    $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_mt5  => $ACCOUNTS{'real\labuan_advanced'},
            to_binary => $test_client->loginid,
            amount    => 50,
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);

    my $account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $account_mock->mock('_fetch_mt5_lc', sub { return 'labuan' });

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $c->call_ok($method, $params)->has_no_error('Withdrawal allowed from labuan mt5 without FA before first deposit');
    cmp_ok $test_client->default_account->balance, '==', 820 + 150 + 50, "Correct balance after withdrawal";

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $c->call_ok(
        'mt5_deposit',
        {
            language => 'EN',
            token    => $token,
            args     => {
                to_mt5      => $ACCOUNTS{'real\labuan_advanced'},
                from_binary => $test_client->loginid,
                amount      => 50,
            },
        })->has_no_error('Deposit allowed to labuan mt5 account without FA');
    cmp_ok $test_client->default_account->balance, '==', 820 + 150, "Correct balance after deposit";

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $c->call_ok($method, $params)->has_error('Withdrawal request failed.')->error_code_is('MT5WithdrawalError', 'error code is MT5WithdrawalError')
        ->error_message_like(qr/complete your financial assessment/);

    $account_mock->mock('_fetch_mt5_lc', sub { return 'svg' });
    $params->{args}->{from_mt5} = $ACCOUNTS{'real\svg'};
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $c->call_ok($method, $params)->has_no_error('Withdrawal allowed from svg mt5 account when sibling labuan account is withdrawal-locked');
    cmp_ok $test_client->default_account->balance, '==', 820 + 150 + 50, "Correct balance after withdrawal";

    $test_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
    $test_client->save;
    $account_mock->mock('_fetch_mt5_lc', sub { return 'labuan' });
    $params->{args}->{from_mt5} = $ACCOUNTS{'real\svg'};
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $c->call_ok($method, $params)->has_no_error('Withdrawal unlocked for labuan mt5 after financial assessment');
    cmp_ok $test_client->default_account->balance, '==', 820 + 150 + 100, "Correct balance after withdrawal";

    $account_mock->unmock;
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
            from_mt5  => $ACCOUNTS{'real\svg'},
            to_binary => $test_mf_client->loginid,
            amount    => 350,
        },
    };

    BOM::RPC::v3::MT5::Account::reset_throttler($test_mf_client->loginid);

    my $method = "mt5_withdrawal";

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return 'maltainvest' });

    $c->call_ok($method, $params_mf)->has_error('Withdrawal request failed.')
        ->error_code_is('MT5WithdrawalError', 'error code is MT5WithdrawalError')->error_message_like(qr/authenticate/);

    $test_mf_client->set_authentication('ID_DOCUMENT')->status('pass');
    $test_mf_client->save();

    BOM::RPC::v3::MT5::Account::reset_throttler($test_mf_client->loginid);

    $c->call_ok($method, $params_mf)->has_no_error('no error for mt5_withdrawal');

    cmp_ok $test_mf_client->default_account->balance, '==', 350, "Correct balance after withdrawal";
    $demo_account_mock->unmock;
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
            to_mt5      => $ACCOUNTS{'real\svg'},
            amount      => 350,
        },
    };

    BOM::RPC::v3::MT5::Account::reset_throttler($test_mf_client->loginid);

    my $method = "mt5_deposit";

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return 'maltainvest' });

    $c->call_ok($method, $params_mf)->has_error('Deposit request failed.')->error_code_is('MT5DepositError', 'error code is MT5DepositError')
        ->error_message_like(qr/authenticate/);

    $test_mf_client->set_authentication('ID_DOCUMENT')->status('pass');
    $test_mf_client->save();

    BOM::RPC::v3::MT5::Account::reset_throttler($test_mf_client->loginid);

    $c->call_ok($method, $params_mf)->has_no_error('no error for mt5_deposit');

    cmp_ok $test_mf_client->default_account->balance, '==', 650, "Correct balance after deposit";
    $demo_account_mock->unmock;
};

subtest 'multi currency transfers' => sub {
    my $client_eur = create_client('CR', undef, {place_of_birth => 'id'});
    my $client_btc = create_client('CR', undef, {place_of_birth => 'id'});
    my $client_ust = create_client('CR', undef, {place_of_birth => 'id'});
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

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return 'svg' });

    my $deposit_params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_binary => $client_eur->loginid,
            to_mt5      => $ACCOUNTS{'real\svg'},
            amount      => $eur_test_amount,
        },
    };

    my $withdraw_params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_mt5  => $ACCOUNTS{'real\svg'},
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

    my $mock_fees = Test::MockModule->new('BOM::Config::CurrencyConfig', no_auto => 1);
    $mock_fees->mock(
        transfer_between_accounts_fees => sub {
            return {
                'USD' => {
                    'UST' => $ust_usd_fee * 100,
                    'BTC' => $btc_usd_fee * 100,
                    'EUR' => $eur_usd_fee * 100
                },
                'UST' => {'USD' => $ust_usd_fee * 100},
                'BTC' => {'USD' => $btc_usd_fee * 100},
                'EUR' => {'USD' => $eur_usd_fee * 100}

            };
        });

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

    $mock_fees->unmock('transfer_between_accounts_fees');
    $demo_account_mock->unmock;
};

subtest 'Transfers Limits' => sub {
    my $EUR_USD = 1.1;
    $redis->hmset(
        'exchange_rates::EUR_USD',
        quote => $EUR_USD,
        epoch => time
    );

    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->MT5(0);
    my $client = create_client('CR');
    $client->set_default_account('EUR');
    top_up $client, EUR => 1000;
    $user->add_client($client);

    my $deposit_params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_binary => $client->loginid,
            to_mt5      => $ACCOUNTS{'real\svg'},
            amount      => 1
        },
    };

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return 'svg' });

    $c->call_ok('mt5_deposit', $deposit_params)->has_error('Transfers should have been stopped')
        ->error_code_is('MT5DepositError', 'Transfers limit - correct error code')
        ->error_message_like(qr/0 transfers a day/, 'Transfers limit - correct error message');

    # unlimit the transfers again
    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->MT5(999);

    $deposit_params->{args}->{amount} = 1 + get_min_unit('EUR') / 10.0;
    $c->call_ok('mt5_deposit', $deposit_params)->has_error('Transfers should have been stopped')
        ->error_code_is('MT5DepositError', 'Transfers limit - correct error code')->error_message_is(
        'Invalid amount. Amount provided can not have more than 2 decimal places.',
        'Transfers amount validation - correct extra decimal error message'
        );

    my $expected_eur_min = financialrounding('amount', 'EUR', 1 / $EUR_USD);    # it is 1 USD converted to EUR

    $deposit_params->{args}->{amount} = $expected_eur_min - get_min_unit('EUR');
    $c->call_ok('mt5_deposit', $deposit_params)->has_error('Transfers should have been stopped')
        ->error_code_is('MT5DepositError', 'Transfers limit - correct error code')
        ->error_message_like(qr/minimum amount for transfers is EUR $expected_eur_min/, 'Transfers minimum - correct error message');

    $EUR_USD = 1000;
    $redis->hmset(
        'exchange_rates::EUR_USD',
        quote => $EUR_USD,
        epoch => time
    );
    my $expected_usd_min = BOM::Config::CurrencyConfig::transfer_between_accounts_limits()->{USD}->{min};
    cmp_ok $expected_usd_min, '>', 10, 'USD-EUR transfer minimum limit elevated to lower bounds by changing exchange rate to $EUR_USD';

    my $withdraw_params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_mt5  => $ACCOUNTS{'real\svg'},
            to_binary => $client->loginid,
            amount    => 1,
        },
    };

    $c->call_ok('mt5_withdrawal', $withdraw_params)->has_error('Transfers should have been stopped')
        ->error_code_is('MT5WithdrawalError', 'Lower bound - correct error code')
        ->error_message_like(qr/minimum amount for transfers is $expected_usd_min USD/, 'Lower bound - correct error message');

    $demo_account_mock->unmock;
};

subtest 'Suspended Transfers Currencies' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies(['BTC']);
    my $client_cr_btc = create_client('CR');
    $client_cr_btc->set_default_account('BTC');
    top_up $client_cr_btc, BTC => 10;
    $user->add_client($client_cr_btc);

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return 'svg' });

    subtest 'it should stop transfer from suspended currency' => sub {
        my $deposit_params = {
            language => 'EN',
            token    => $token,
            args     => {
                from_binary => $client_cr_btc->loginid,
                to_mt5      => $ACCOUNTS{'real\svg'},
                amount      => 1
            },
        };

        $c->call_ok('mt5_deposit', $deposit_params)->has_error('Transfers should have been stopped')
            ->error_code_is('MT5DepositError', 'Transfer from suspended currency not allowed - correct error code')
            ->error_message_like(qr/BTC and USD are currently unavailable/, 'Transfer from suspended currency not allowed - correct error message');

    };
    BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies([]);
    $demo_account_mock->unmock;
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
