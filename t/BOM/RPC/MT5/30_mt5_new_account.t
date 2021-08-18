use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use JSON::MaybeUTF8;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::MT5::User::Async;
use BOM::Platform::Token;
use BOM::User;

use Test::BOM::RPC::Accounts;

my $c = BOM::Test::RPC::QueueClient->new();

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my %accounts       = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %details        = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;
my %financial_data = %Test::BOM::RPC::Accounts::FINANCIAL_DATA;

# Setup a test user
my $test_client    = create_client('CR');
my $test_client_vr = create_client('VRTC');

$test_client->email($details{email});
$test_client->set_default_account('USD');
$test_client->binary_user_id(1);

$test_client_vr->email($details{email});
$test_client_vr->set_default_account('USD');

$test_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
$test_client->save;

$test_client_vr->save;

my $password = 's3kr1t';
my $hash_pwd = BOM::User::Password::hashpw($password);
my $user     = BOM::User->create(
    email    => $details{email},
    password => $hash_pwd,
);
$user->update_trading_password($details{password}{main});
$user->add_client($test_client);
$user->add_client($test_client_vr);

my %basic_details = (
    place_of_birth            => "af",
    tax_residence             => "af",
    tax_identification_number => "1122334455",
    account_opening_reason    => "testing"
);

$test_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
$test_client->save;

my $m        = BOM::Platform::Token::API->new;
my $token    = $m->create_token($test_client->loginid,    'test token');
my $token_vr = $m->create_token($test_client_vr->loginid, 'test token');

# Throttle function limits requests to 1 per minute which may cause
# consecutive tests to fail without a reset.
BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

subtest 'new account with invalid main or investor password format' => sub {
    my $method                   = 'mt5_new_account';
    my $wrong_formatted_password = 'abc123';
    my $params                   = {
        language => 'EN',
        token    => $token,
        args     => {
            email            => $details{email},
            name             => $details{name},
            account_type     => "demo",
            address          => "Dummy address",
            city             => "Valletta",
            company          => "Deriv Limited",
            country          => "mt",
            mainPassword     => "abc123",
            mt5_account_type => "financial",
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
        ->error_message_is('Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'error code for mt5_new_account wrong password formatting');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $params->{args}->{mainPassword}   = 'ABCDE123';
    $params->{args}->{investPassword} = 'ABCDEFGE';
    $c->call_ok($method, $params)->has_error('error code for mt5_new_account wrong investor password formatting')
        ->error_code_is('IncorrectMT5PasswordFormat', 'error code for mt5_new_account wrong investor password formatting')
        ->error_message_is('Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'error code for mt5_new_account wrong investor password formatting');

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
            mt5_account_type => 'financial_stp',
            country          => 'mt',
            email            => $details{email},
            name             => $details{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $details{password}{main},
            leverage         => 100,
        },
    };

    $c->call_ok($method, $params)->has_error('error from missing signup details')
        ->error_code_is('ASK_FIX_DETAILS', 'error code for missing basic details')
        ->error_details_is({missing => ['phone', 'account_opening_reason']}, 'missing field in response details');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $test_client->status->clear_crs_tin_information;
    $test_client->phone('12345678');
    $test_client->account_opening_reason('no reason');
    $test_client->save;
};

subtest 'new account' => sub {
    $test_client->user->update_trading_password($details{password}{main});
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            country      => 'mt',
            email        => $details{email},
            name         => $details{name},
            mainPassword => $details{password}{main},
            leverage     => 100,
        },
    };
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);
    $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account without investPassword');
    is($c->result->{login},           'MTR' . $accounts{'real\p01_ts03\synthetic\svg_std_usd\01'}, 'result->{login}');
    is($c->result->{balance},         0,                                                           'Balance is 0 upon creation');
    is($c->result->{display_balance}, '0.00',                                                      'Display balance is "0.00" upon creation');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $c->call_ok($method, $params)->has_error('error from duplicate mt5_new_account')
        ->error_code_is('MT5CreateUserError', 'error code for duplicate mt5_new_account');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
};

subtest 'new account dry_run' => sub {
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            country      => 'mt',
            email        => $details{email},
            name         => $details{name},
            mainPassword => $details{password}{main},
            leverage     => 100,
            dry_run      => 1
        },
    };
    $c->call_ok($method, $params)->has_no_error('mt5 new account dry run only runs validations');
    is($c->result->{balance},         0,      'Balance is 0 upon dry run');
    is($c->result->{display_balance}, '0.00', 'Display balance is "0.00" upon dry run');
    is($c->result->{currency},        'USD',  'Currency is "USD" upon dry run');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
};

subtest 'new account with account in highRisk groups' => sub {
    my $mock_mt5_rpc = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mock_mt5_rpc->mock(
        get_mt5_logins => sub {
            return Future->done({
                login    => '1001014',
                group    => 'real\p01_ts01\synthetic\svg_std-hr_usd',
                balance  => 0,
                currency => 'USD',
            });
        });

    my $new_email  = 'highrisk' . $details{email};
    my $new_client = create_client('CR', undef, {residence => 'id'});
    my $token      = $m->create_token($new_client->loginid, 'test token');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);

    my $user = BOM::User->create(
        email    => $new_email,
        password => 's3kr1t',
    );
    $user->update_trading_password($details{password}{main});
    $user->add_client($new_client);

    subtest 'corresponding high risk group exists' => sub {
        my $method = 'mt5_new_account';
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_type => 'gaming',
                country      => 'id',
                email        => $details{email},
                name         => $details{name},
                mainPassword => $details{password}{main},
                leverage     => 100,
                server       => 'p01_ts02',
            },
        };

        BOM::RPC::v3::MT5::Account::reset_throttler($new_client->loginid);
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);
        $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account without investPassword');
        is $c->result->{login}, 'MTR' . $accounts{'real\p01_ts02\synthetic\svg_std-hr_usd'}, 'group changed to high risk';
    };

    subtest 'corresponding high risk group does not exist' => sub {
        $mock_mt5_rpc->mock(
            get_mt5_account_type_config => sub {
                my ($group) = @_;

                return undef if $group =~ /\-hr/;
                return $mock_mt5_rpc->original('get_mt5_account_type_config')->($group);
            });

        my $method = 'mt5_new_account';
        my $params = {
            language => 'EN',
            token    => $token,
            args     => {
                account_type => 'gaming',
                country      => 'id',
                email        => $details{email},
                name         => $details{name},
                mainPassword => $details{password}{main},
                leverage     => 100,
                server       => 'p01_ts03',
            },
        };

        BOM::RPC::v3::MT5::Account::reset_throttler($new_client->loginid);
        BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);
        $c->call_ok($method, $params)->has_error('high risk group does not exist for corresponding group')
            ->error_code_is('MT5CreateUserError', 'error code for mt5_new_account with navailable high risk group')
            ->error_message_is('An error occured while creating your account. Please check your information and try again.');
    };

    $mock_mt5_rpc->unmock_all();
};

subtest 'status allow_document_upload is added upon mt5 create account dry_run advanced' => sub {
    my $ID_DOCUMENT = $test_client->get_authentication('ID_DOCUMENT')->status;

    $test_client->set_authentication('ID_DOCUMENT', {status => 'pending'});
    $test_client->tax_residence('mt');
    $test_client->tax_identification_number('111222333');
    $test_client->save;
    ok !$test_client->fully_authenticated, 'Not fully authenticated';
    my $method = 'get_account_status';
    my $params = {token => $token};
    $c->call_ok($method, $params);
    my $status = $c->result->{status};
    ok(!grep(/^allow_document_upload$/, @$status), 'allow_document_upload status not present');

    $method = 'mt5_new_account';
    $params = {
        token => $token,
        args  => {
            account_type     => 'financial',
            country          => 'mt',
            email            => $details{email},
            name             => $details{name},
            mainPassword     => $details{password}{main},
            leverage         => 100,
            dry_run          => 1,
            mt5_account_type => 'financial_stp',
        },
    };
    $c->call_ok($method, $params)->has_error->error_code_is('AuthenticateAccount', 'error code is AuthenticateAccount');

    $method = 'get_account_status';
    $params = {token => $token};
    $c->call_ok($method, $params);
    $status = $c->result->{status};
    ok(grep(/^allow_document_upload$/, @$status), 'allow_document_upload status present');

    $test_client->set_authentication('ID_DOCUMENT', {status => $ID_DOCUMENT});
    $test_client->save;
};

subtest 'new account dry_run using invalid arguments' => sub {
    my $method = 'mt5_new_account';

    # Invalid account type
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'an_invalid_account_type',
            country      => 'mt',
            email        => $details{email},
            name         => $details{name},
            mainPassword => $details{password}{main},
            leverage     => 100,
            dry_run      => 1
        },
    };
    $c->call_ok($method, $params)->has_error('invalid account_type on dry run')
        ->error_code_is('InvalidAccountType', 'invalid account_type entered on dry run')
        ->error_message_like(qr/We can't find this account/, 'error message for invalid account_type entered on dry run');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    # Invalid sub account type
    $params->{args}->{account_type}     = 'financial';
    $params->{args}->{mt5_account_type} = 'invalid_account_type';

    $c->call_ok($method, $params)->has_error('invalid mt5_account_type on dry run')
        ->error_code_is('InvalidSubAccountType', 'invalid mt5_account_type entered on dry run')
        ->error_message_like(qr/We can't find this account/, 'error message for invalid mt5_account_type entered on dry run');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
};

subtest 'new account dry_run on a client with no account currency' => sub {
    my $test_client_with_no_currency = create_client('CR');
    my $method                       = 'mt5_new_account';
    my $params                       = {
        language => 'EN',
        token    => $m->create_token($test_client_with_no_currency->loginid, 'test token'),
        args     => {
            account_type => 'gaming',
            country      => 'mt',
            email        => $details{email},
            name         => $details{name},
            mainPassword => $details{password}{main},
            leverage     => 100,
            dry_run      => 1
        },
    };

    $c->call_ok($method, $params)->has_error('no currency set for the account')
        ->error_code_is('SetExistingAccountCurrency', 'provided client has no default currency on dry run')
        ->error_message_like(qr/Please set your account currency./, 'error message for client with no default currency on dry run');

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
            email          => $details{email},
            name           => $details{name},
            investPassword => 'Abcd1234',
            mainPassword   => $details{password}{main},
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
            mt5_account_type => 'financial',
            country          => 'es',
            email            => $details{email},
            name             => $details{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $details{password}{main},
        },
    };

    $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account for financial with no tax information');

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
    $switch_user->update_trading_password($details{password}{main});
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
            email          => $details{email},
            name           => $details{name},
            investPassword => 'Abcd1234',
            mainPassword   => $details{password}{main},
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
    $params->{args}->{mt5_account_type} = 'financial';

    BOM::RPC::v3::MT5::Account::reset_throttler($mf_switch_client->loginid);
    BOM::RPC::v3::MT5::Account::reset_throttler($mlt_switch_client->loginid);

    $c->call_ok($method, $params)->has_no_error('financial account should be created');
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
    $switch_user->update_trading_password($details{password}{main});
    my $mlt_switch_token = $m->create_token($mlt_switch_client->loginid, 'test token');

    # we should get an error if we are trying to open a financial account

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $mlt_switch_token,
        args     => {
            account_type     => 'financial',
            mt5_account_type => 'financial',
            country          => 'es',
            email            => $details{email},
            name             => $details{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $details{password}{main},
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
    $switch_user->update_trading_password($details{password}{main});

    my $vr_switch_token = $m->create_token($vr_switch_client->loginid, 'test token');

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $vr_switch_token,
        args     => {
            account_type   => 'gaming',
            country        => 'es',
            email          => $details{email},
            name           => $details{name},
            investPassword => 'Abcd1234',
            mainPassword   => $details{password}{main},
        },
    };

    BOM::RPC::v3::MT5::Account::reset_throttler($mlt_switch_client->loginid);
    $c->call_ok($method, $params)->has_error('cannot create gaming account for VRTC only users')
        ->error_code_is('RealAccountMissing', 'error should be permission denied');

    BOM::RPC::v3::MT5::Account::reset_throttler($mlt_switch_client->loginid);

    # Add dry_run test, we should get exact result like previous test
    $params->{args}->{dry_run} = 1;
    $c->call_ok($method, $params)->has_error('cannot create gaming account for VRTC only users even on dry_run')
        ->error_code_is('RealAccountMissing', 'error should be permission denied on dry_run');

    # Reset params after dry_run test
    $params->{args}->{dry_run} = 0;
    BOM::RPC::v3::MT5::Account::reset_throttler($mlt_switch_client->loginid);

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
            mt5_account_type => 'financial',
            country          => 'es',
            email            => $details{email},
            name             => $details{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $details{password}{main},
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

subtest 'new account on addtional trade server' => sub {
    my $mocked = Test::MockModule->new('BOM::Config');
    $mocked->mock(
        'mt5_server_routing',
        sub {
            return {
                real => {},
                demo => {}};
        });
    my $new_email  = 'abc' . $details{email};
    my $new_client = create_client('CR', undef, {residence => 'za'});
    my $token      = $m->create_token($new_client->loginid, 'test token');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);

    my $user = BOM::User->create(
        email    => $new_email,
        password => 's3kr1t',
    );
    $user->update_trading_password($details{password}{main});
    $user->add_client($new_client);

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            email        => $new_email,
            name         => $details{name},
            mainPassword => $details{password}{main},
            leverage     => 100,
        },
    };
    note("creates a gaming account with old server config");
    $c->call_ok($method, $params)->has_no_error('mt5 new account with old config za goes real\p01_ts01');
    is($c->result->{balance},         0,                                                           'Balance is 0');
    is($c->result->{display_balance}, '0.00',                                                      'Display balance is "0.00"');
    is($c->result->{currency},        'USD',                                                       'Currency is "USD"');
    is($c->result->{login},           'MTR' . $accounts{'real\p01_ts01\synthetic\svg_std_usd\01'}, 'login is MTR00001013');

    BOM::RPC::v3::MT5::Account::reset_throttler($new_client->loginid);
    note('suspend mt5 real\p01_ts02. Tries to create financial account with new config.');
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts02->all(1);
    $mocked->unmock_all;
    $params->{args}{account_type}     = 'financial';
    $params->{args}{mt5_account_type} = 'financial';
#    $c->call_ok($method, $params)->has_no_error('mt5 new account with new config');
#    is($c->result->{balance},         0,             'Balance is 0');
#    is($c->result->{display_balance}, '0.00',        'Display balance is "0.00"');
#    is($c->result->{currency},        'USD',         'Currency is "USD"');
#    is($c->result->{login},           'MTR000\p01_ts01\p01_ts016', 'login is MTR000\p01_ts01\p01_ts016');
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts02->all(0);

    note('unsuspend mt5 real\p01_ts02. Tries to create financial account with new config.');
    BOM::RPC::v3::MT5::Account::reset_throttler($new_client->loginid);
    $params->{args}{mt5_account_category} = 'swap_free';
    $c->call_ok($method, $params)->has_no_error('mt5 new account with new config');
    is($c->result->{login}, 'MTR' . $accounts{'real\p01_ts01\financial\svg_sf_usd'}, 'login is MTR20000002');
    $mocked->unmock_all;
};

subtest 'new account identical account check' => sub {
    my $mock_mt5_rpc = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mock_mt5_rpc->mock(
        get_mt5_logins => sub {
            return Future->done({
                login    => 'MTR100\p01_ts01',
                group    => 'real\svg',
                balance  => 1000,
                currency => 'USD',
            });
        });
    my $new_email  = 'abcd' . $details{email};
    my $new_client = create_client('CR', undef, {residence => 'za'});
    my $token      = $m->create_token($new_client->loginid, 'test token');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);

    my $user = BOM::User->create(
        email    => $new_email,
        password => 's3kr1t',
    );
    $user->update_trading_password($details{password}{main});
    $user->add_client($new_client);

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            email        => $new_email,
            name         => $details{name},
            mainPassword => $details{password}{main},
            leverage     => 100,
        },
    };
    note("creates a gaming account with existing account with old group name on a different server is allowed");
    $c->call_ok($method, $params)->has_no_error('can create synthetic account on real\p01_ts02 when clean has identical account on real\p01_ts01');
};

subtest 'country=za; creates financial account with existing gaming account while real\p01_ts02 disabled' => sub {
    my $new_email  = 'abcdef' . $details{email};
    my $new_client = create_client('CR', undef, {residence => 'za'});
    my $token      = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('USD');
    $new_client->email($new_email);

    my $user = BOM::User->create(
        email    => $new_email,
        password => 's3kr1t',
    );
    $user->update_trading_password($details{password}{main});
    $user->add_client($new_client);

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            email        => $new_email,
            name         => $details{name},
            mainPassword => $details{password}{main},
            leverage     => 100,
        },
    };
    my $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
    is $result->{account_type}, 'gaming', 'account_type=gaming';
    is $result->{login}, 'MTR' . $accounts{'real\p01_ts02\synthetic\svg_std_usd\01'}, 'created in group real\p01_ts02\synthetic\svg_std_usd\01';

    BOM::RPC::v3::MT5::Account::reset_throttler($new_client->loginid);
    note("disable real->p01_ts02 API calls.");
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts02->all(1);

    $params->{args}{account_type}     = 'financial';
    $params->{args}{mt5_account_type} = 'financial';
    my $financial = $c->call_ok($method, $params)->has_no_error->result;
    is $financial->{account_type}, 'financial', 'account_type=financial';
    is $financial->{login}, 'MTR' . $accounts{'real\p01_ts01\financial\svg_std_usd'}, 'created in group real\p01_ts01\financial\svg_std_usd';
};

subtest 'country=au, financial account' => sub {
    my $new_email  = 'au' . $details{email};
    my $new_client = create_client('CR', undef, {residence => 'au'});
    my $token      = $m->create_token($new_client->loginid, 'test token 2');
    $new_client->set_default_account('AUD');
    $new_client->email($new_email);

    my $user = BOM::User->create(
        email    => $new_email,
        password => 's3kr1t',
    );
    $user->update_trading_password($details{password}{main});
    $user->add_client($new_client);

    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'financial',
            mt5_account_type => 'financial',
            email            => $new_email,
            name             => $details{name},
            mainPassword     => $details{password}{main},
            leverage         => 100,
        },
    };
    my $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
    is $result->{account_type}, 'financial', 'account_type=financial';
    is $result->{login}, 'MTR' . $accounts{'real\p01_ts01\financial\svg_std-lim_usd'}, 'created in group real\p01_ts01\financial\svg_std-lim_usd';

    BOM::RPC::v3::MT5::Account::reset_throttler($new_client->loginid);
    $params->{args}->{account_type} = 'demo';
    $result = $c->call_ok($method, $params)->has_no_error('gaming account successfully created')->result;
    is $result->{account_type}, 'demo', 'account_type=demo';
    is $result->{login}, 'MTD' . $accounts{'demo\p01_ts01\financial\svg_std-lim_usd'}, 'created in group demo\p01_ts01\financial\svg_std-lim_usd';

    BOM::RPC::v3::MT5::Account::reset_throttler($new_client->loginid);
    $params->{args}->{account_type}     = 'financial';
    $params->{args}->{mt5_account_type} = 'financial_stp';
    $result                             = $c->call_ok($method, $params)->has_error->error_code_is('MT5NotAllowed')
        ->error_message_is('MT5 financial account is not available in your country yet.');

    BOM::RPC::v3::MT5::Account::reset_throttler($new_client->loginid);
    $params->{args}->{mt5_account_type} = 'financial';
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->auto_Bbook_svg_financial(0);
    # same account 'real\p01_ts01\financial\svg_std-lim_usd' is already created
    $result =
        $c->call_ok($method, $params)->has_error->error_code_is('MT5CreateUserError')
        ->error_message_is(
        'An account already exists with the information you provided. If you\'ve forgotten your username or password, please contact us.');
};

done_testing();
